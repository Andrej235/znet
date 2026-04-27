const std = @import("std");
const http = @import("../../http/http.zig");

const ConnectionReader = @import("../connection_reader.zig").ConnectionReader;
const RequestValidationError = @import("../validation_errors/request_validation_error.zig").RequestValidationError;

const Parser = @import("./parser.zig").Parser;
const Request = @import("../../requests/request.zig").Request;
const RequestHost = @import("../../app/host/request_host.zig").RequestHost;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.http1_parser);

const HttpState = enum {
    request_line,
    headers,
    body,
    complete,
};

pub const Http1Parser = struct {
    parse_offset: usize,

    method: ?http.Method = null,
    version: ?http.Version = null,
    path: ?[]const u8 = null,
    host: ?RequestHost = null,

    state: HttpState = .request_line,
    waiting_to_consume: bool = false, // whether we've encountered an error and are waiting to consume the rest of the request before parsing the next one
    validation_error: ?RequestValidationError = null, // must not be null if waiting_to_consume is true

    connection: http.Connection = .keep_alive, // http 1.1 assumes keep-alive connections by default

    body_start: ?usize = null,
    body_size: ?usize = null,

    transfer_encoding: http.TransferEncoding = .none,
    current_chunk_size: ?usize = null,

    content_type: ?http.RequestContentType = null,
    accepts: ?[]const u8 = null,

    pub fn init() Http1Parser {
        return .{
            .parse_offset = 0,
        };
    }

    pub fn parse(self: *Http1Parser, conn: *ConnectionReader) Parser.ParseResult {
        if (self.state == .complete) {
            self.resetState();
        }

        if (self.waiting_to_consume) {
            return self.tryConsumeRequestOnError(conn, self.validation_error.?);
        }

        const buf = conn.current_buffer[self.parse_offset..conn.buffered_bytes];
        var reader = std.io.Reader.fixed(buf);

        while (reader.takeDelimiterInclusive('\n') catch null) |line| {
            if (line[line.len - 2] != '\r') {
                // invalid line ending, http1 requires \r\n
                Logger.err("Invalid HTTP1 line ending", .{});

                return .{
                    .unrecoverable_err = null,
                };
            }

            self.parse_offset += line.len;

            switch (self.state) {
                .request_line => {
                    if (line.len == 2) {
                        // empty request line
                        return .{
                            .unrecoverable_err = null,
                        };
                    }

                    var line_reader = std.io.Reader.fixed(line[0 .. line.len - 2]); // exclude \r\n
                    if (line_reader.takeDelimiter(' ') catch return .{ .unrecoverable_err = null }) |method| {
                        if (line_reader.takeDelimiter(' ') catch return .{ .unrecoverable_err = null }) |path| {
                            const version = line_reader.buffer[line_reader.seek..];

                            self.state = .headers;
                            self.method = http.Method.fromString(method) orelse {
                                Logger.err("Unsupported HTTP method: {s}", .{method});
                                // todo:? implement arbitrary methods because spec supports them
                                return self.tryConsumeRequestOnError(conn, .{
                                    .error_code = .not_implemented,
                                    .message = "Unsupported HTTP method",
                                });
                            };
                            self.path = path;
                            self.version = http.Version.fromString(version) orelse {
                                Logger.err("Unsupported HTTP version: {s}", .{version});
                                return .{
                                    .unrecoverable_err = .{
                                        .error_code = .http_version_not_supported,
                                        .message = "Unsupported HTTP version",
                                    },
                                };
                            };
                        }
                    }
                },

                .headers => {
                    if (line.len == 2) {
                        // headers end with \r\n\r\n
                        self.state = .body;
                        self.body_start = self.parse_offset;
                        break;
                    }

                    const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse {
                        Logger.err("Invalid HTTP header line (no colon found): {any}", .{line});
                        return .{
                            .unrecoverable_err = null,
                        };
                    };

                    const header_name = line[0..colon_index];
                    const header_value = std.mem.trim(u8, line[colon_index + 1 .. line.len - 2], &std.ascii.whitespace);

                    const header_res = self.parseHeader(header_name, header_value);
                    switch (header_res) {
                        .success => {},
                        .err => |err| {
                            return self.tryConsumeRequestOnError(conn, err);
                        },
                        .unrecoverable_err => |err| {
                            return .{
                                .unrecoverable_err = err,
                            };
                        },
                    }
                },

                .body => {
                    @branchHint(.cold);
                    Logger.err("Tried http parsing body inside while loop", .{});
                    break;
                },

                .complete => {
                    @branchHint(.cold);
                    Logger.err("Tried http parsing after finishing parsing a request", .{});
                    break;
                },
            }
        }

        if (self.state != .body) {
            // we haven't finished parsing headers yet, wait for more data
            return .needs_more_data;
        }

        const body_result = self.parseBody(conn);
        switch (body_result) {
            .success => |body| {
                if (self.host == null) {
                    // this is only called after consuming the entire request so there's no need to call tryConsumeRequestOnError
                    return .{
                        .err = .{
                            .keep_alive = false,
                            .validation_error = .{
                                .error_code = .bad_request,
                                .message = "Missing Host header",
                            },
                            .consumed_bytes = self.parse_offset,
                        },
                    };
                }

                return .{
                    .success = .{
                        .request = Request{
                            .http = .{
                                .host = self.host.?,

                                .method = self.method.?,
                                .version = self.version.?,
                                .path = self.path.?,

                                .connection = self.connection,

                                .body = body,
                                .chunked = self.transfer_encoding == .chunked,
                                .accepts = self.accepts,
                                .content_type = self.content_type,
                            },
                        },
                        .consumed_bytes = self.parse_offset,
                    },
                };
            },
            .needs_more_data => return .needs_more_data,
            .unrecoverable_err => |err| {
                return .{
                    .unrecoverable_err = err,
                };
            },
        }
    }

    fn resetState(self: *Http1Parser) void {
        self.parse_offset = 0;
        self.method = null;
        self.version = null;
        self.path = null;

        self.connection = .keep_alive;

        self.state = .request_line;
        self.waiting_to_consume = false;
        self.validation_error = null;
        self.body_size = null;
        self.transfer_encoding = .none;
    }

    const ParseHeaderResult = union(enum) {
        success,
        err: RequestValidationError,
        unrecoverable_err: ?RequestValidationError,
    };

    /// Value must be trimmed before being passed in
    inline fn parseHeader(self: *Http1Parser, name: []const u8, value: []const u8) ParseHeaderResult {
        if (std.ascii.eqlIgnoreCase(name, "Host")) {
            if (self.host) |_| {
                return .{
                    .err = .{
                        .error_code = .bad_request,
                        .message = "Multiple Host headers are not allowed",
                    },
                };
            }

            self.host = RequestHost.fromHostStr(value) catch return .{
                .err = .{
                    .error_code = .bad_request,
                    .message = "Invalid Host",
                },
            };
            return .success;
        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const length = std.fmt.parseInt(usize, value, 10) catch {
                Logger.err("Invalid Content-Length header value: {s}", .{value});
                return .{
                    .unrecoverable_err = .{
                        .error_code = .bad_request,
                        .message = "Invalid Content-Length",
                    },
                };
            };
            self.body_size = length;

            return .success;
        }

        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (http.TransferEncoding.fromString(value)) |te| {
                self.transfer_encoding = te;
                return .success;
            }

            Logger.err("Unsupported Transfer-Encoding header value: {s}", .{value});
            return .{
                .unrecoverable_err = .{
                    .error_code = http.StatusCode.not_implemented,
                    .message = "Unsupported Transfer-Encoding",
                },
            };
        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            self.content_type = http.RequestContentType.fromString(value) orelse {
                Logger.err("Unsupported Content-Type header value: {s}", .{value});
                return .{
                    .err = .{
                        .error_code = http.StatusCode.unsupported_media_type,
                        .message = "Unsupported Content-Type",
                    },
                };
            };
        }

        if (std.ascii.eqlIgnoreCase(name, "Accept")) {
            self.accepts = value;
            return .success;
        }

        if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                self.connection = .close;
            }

            return .success;
        }

        return .success;
    }

    const ParseBodyResult = union(enum) {
        success: ?[]const u8,
        needs_more_data,
        unrecoverable_err: ?RequestValidationError,
    };

    fn parseBody(self: *Http1Parser, conn: *ConnectionReader) ParseBodyResult {
        if (self.transfer_encoding == .chunked and self.body_size != null) {
            return .{
                .unrecoverable_err = null,
            };
        }

        const buf = conn.current_buffer;

        if (self.transfer_encoding == .chunked) {
            var reader = std.io.Reader.fixed(buf[self.parse_offset..conn.buffered_bytes]);

            // we only break out if we have enough data buffered, otherwise we return .needs_more_data or an error
            while (true) {
                if (self.current_chunk_size) |chunk_size| {
                    if (chunk_size == 0) {
                        // last chunk, we're done
                        break;
                    }

                    if (conn.buffered_bytes < self.parse_offset + chunk_size) {
                        // not enough data buffered yet
                        return .needs_more_data;
                    }

                    // consume chunk data, no need to parse it here
                    self.parse_offset += chunk_size + 2; // consume chunk data and \r\n
                    _ = reader.take(chunk_size + 2) catch unreachable;

                    // chunk must end with \r\n
                    if (buf[self.parse_offset - 2] != '\r' or buf[self.parse_offset - 1] != '\n') {
                        Logger.err("Invalid chunk ending", .{});
                        return .{
                            .unrecoverable_err = .{
                                .error_code = .bad_request,
                                .message = "Invalid chunk",
                            },
                        };
                    }

                    self.current_chunk_size = null; // reset for next chunk
                } else {
                    if (reader.takeDelimiter('\n') catch null) |chunk_size_line| {
                        if (chunk_size_line.len < 2 or chunk_size_line[chunk_size_line.len - 1] != '\r') {
                            Logger.err("Invalid chunk size line ending {any}", .{chunk_size_line});
                            return .{
                                .unrecoverable_err = .{
                                    .error_code = .bad_request,
                                    .message = "Invalid chunk",
                                },
                            };
                        }

                        const chunk_size_str = chunk_size_line[0 .. chunk_size_line.len - 1]; // exclude \r
                        self.current_chunk_size = std.fmt.parseInt(usize, chunk_size_str, 16) catch {
                            Logger.err("Invalid chunk size: {any}", .{chunk_size_str});
                            return .{
                                .unrecoverable_err = .{
                                    .error_code = .bad_request,
                                    .message = "Invalid chunk",
                                },
                            };
                        };

                        self.parse_offset += chunk_size_line.len + 1; // consume chunk size line and \n
                    } else {
                        // not enough data buffered yet
                        return .needs_more_data;
                    }
                }
            }
        } else if (self.body_size) |size| {
            if (conn.buffered_bytes < self.parse_offset + size) {
                // not enough data buffered yet
                return .needs_more_data;
            }

            // consume body data, no need to parse it here
            self.parse_offset += size;
        }

        self.state = .complete;
        return .{
            .success = buf[self.body_start.?..self.parse_offset],
        };
    }

    // we do not care about non critical errors while just attempting to consume the request
    const ConsumeHeaderResult = union(enum) {
        success,
        unrecoverable_err: ?RequestValidationError,
    };

    inline fn consumeHeader(self: *Http1Parser, name: []const u8, value: []const u8) ConsumeHeaderResult {
        if (value.len == 0) { // we don't care about invalid header values, just structure
            return .success;
        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const length = std.fmt.parseInt(usize, value, 10) catch {
                Logger.err("Invalid Content-Length header value: {s}", .{value});
                return .{
                    .unrecoverable_err = .{
                        .error_code = .bad_request,
                        .message = "Invalid Content-Length",
                    },
                };
            };
            self.body_size = length;

            return .success;
        }

        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (http.TransferEncoding.fromString(value)) |te| {
                self.transfer_encoding = te;
                return .success;
            }

            Logger.err("Unsupported Transfer-Encoding header value: {s}", .{value});
            return .{
                .unrecoverable_err = .{
                    .error_code = http.StatusCode.not_implemented,
                    .message = "Unsupported Transfer-Encoding",
                },
            };
        }

        if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                self.connection = .close;
            }

            return .success;
        }

        return .success;
    }

    fn tryConsumeRequestOnError(self: *Http1Parser, conn: *ConnectionReader, err: RequestValidationError) Parser.ParseResult {
        const buf = conn.current_buffer[self.parse_offset..conn.buffered_bytes];
        var reader = std.io.Reader.fixed(buf);

        while (reader.takeDelimiterInclusive('\n') catch null) |line| {
            if (line[line.len - 2] != '\r') {
                // invalid line ending, http1 requires \r\n
                Logger.err("Invalid HTTP1 line ending", .{});

                return .{
                    .unrecoverable_err = null,
                };
            }

            self.parse_offset += line.len;

            switch (self.state) {
                .request_line => {
                    // if we can't even parse the request line, the main parsing loop should reject the request outright without trying to consume it
                    // this is just a safeguard and should never happen

                    @branchHint(.cold);
                    return .{
                        .unrecoverable_err = err,
                    };
                },

                .headers => {
                    if (line.len == 2) {
                        // headers end with \r\n\r\n
                        self.state = .body;
                        self.body_start = self.parse_offset;
                        break;
                    }

                    const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse {
                        Logger.err("Invalid HTTP header line (no colon found): {any}", .{line});
                        return .{
                            .unrecoverable_err = null,
                        };
                    };

                    const header_name = line[0..colon_index];
                    const header_value = std.mem.trim(u8, line[colon_index + 1 .. line.len - 2], &std.ascii.whitespace);

                    const header_result = self.consumeHeader(header_name, header_value);
                    switch (header_result) {
                        .success => {},
                        .unrecoverable_err => |header_err| {
                            // prioritize structural errors over the original error that caused us to consume the request
                            return .{
                                .unrecoverable_err = header_err,
                            };
                        },
                    }
                },

                .body => {
                    @branchHint(.cold);
                    Logger.err("Tried http parsing body inside while loop", .{});
                    break;
                },

                .complete => {
                    @branchHint(.cold);
                    Logger.err("Tried http parsing after finishing parsing a request", .{});
                    break;
                },
            }
        }

        if (self.state != .body) {
            // we haven't finished parsing headers yet, wait for more data
            return .needs_more_data;
        }

        const body_result = self.parseBody(conn);
        switch (body_result) {
            .success => return .{
                .err = .{
                    .keep_alive = self.connection == .keep_alive,
                    .validation_error = err,
                    .consumed_bytes = self.parse_offset,
                },
            },
            .needs_more_data => return .needs_more_data,
            .unrecoverable_err => |body_err| {
                // prioritize structural errors over the original error that caused us to consume the request
                return .{
                    .unrecoverable_err = body_err,
                };
            },
        }
    }
};
