const std = @import("std");
const http = @import("../../http/http.zig");

const ConnectionReader = @import("../connection_reader.zig").ConnectionReader;

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

const TransferEncoding = enum {
    none,
    chunked,
};

pub const Http1Parser = struct {
    parse_offset: usize,

    method: ?http.Method = null,
    version: ?http.Version = null,
    path: ?[]const u8 = null,
    host: ?RequestHost = null,

    state: HttpState = .request_line,

    connection: http.Connection = .keep_alive, // http 1.1 assumes keep-alive connections by default

    body_start: ?usize = null,
    body_size: ?usize = null,

    transfer_encoding: TransferEncoding = .none,
    current_chunk_size: ?usize = null,

    content_type: ?http.RequestContentType = null,
    accepts: ?[]const u8 = null,

    pub fn init() Http1Parser {
        return .{
            .parse_offset = 0,
        };
    }

    pub const Errors = error{
        MissingHostHeader,

        InvalidHeaders,
        InvalidChunkedEncoding,
        InvalidRequestLine,
        InvalidHostHeader,

        UnsupportedMethod,
        UnsupportedVersion,
        UnsupportedTransferEncoding,
    };

    // todo: implement better error handling, make sure to consume the entire request even if invalid
    // only reject a request if it's structurally invalid, in which case do not persist the connection
    pub fn parse(self: *Http1Parser, conn: *ConnectionReader) Errors!?Parser.ParseResult {
        if (self.state == .complete) {
            self.resetState();
        }

        const buf = conn.current_buffer[self.parse_offset..conn.buffered_bytes];
        var reader = std.io.Reader.fixed(buf);

        while (reader.takeDelimiterInclusive('\n') catch null) |line| {
            if (line[line.len - 2] != '\r') {
                // invalid line ending, http1 requires \r\n
                Logger.err("Invalid HTTP1 line ending", .{});
                return error.InvalidHeaders;
            }

            self.parse_offset += line.len;

            switch (self.state) {
                .request_line => {
                    if (line.len == 2) {
                        // empty request line
                        return error.InvalidHeaders;
                    }

                    var line_reader = std.io.Reader.fixed(line[0 .. line.len - 2]); // exclude \r\n
                    if (line_reader.takeDelimiter(' ') catch return Errors.InvalidRequestLine) |method| {
                        if (line_reader.takeDelimiter(' ') catch return Errors.InvalidRequestLine) |path| {
                            const version = line_reader.buffer[line_reader.seek..];

                            self.state = .headers;
                            self.method = http.Method.fromString(method) orelse {
                                Logger.err("Unsupported HTTP method: {s}", .{method});
                                // todo:? implement arbitrary methods because spec supports them
                                return Errors.UnsupportedMethod;
                            };
                            self.path = path;
                            self.version = http.Version.fromString(version) orelse {
                                Logger.err("Unsupported HTTP version: {s}", .{version});
                                return Errors.UnsupportedVersion;
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
                        return Errors.InvalidHeaders;
                    };

                    const header_name = line[0..colon_index];
                    const header_value = std.mem.trim(u8, line[colon_index + 1 .. line.len - 2], &std.ascii.whitespace);

                    try self.parseHeader(header_name, header_value);
                },

                .body => {
                    Logger.err("Tried http parsing body inside while loop", .{});
                    break;
                },

                .complete => {
                    Logger.err("Tried http parsing after finishing parsing a request", .{});
                    break;
                },
            }
        }

        if (self.state != .body) {
            // we haven't finished parsing headers yet, wait for more data
            return null;
        }

        if (self.transfer_encoding == .chunked) {
            // we only break out if we have enough data buffered, otherwise we return null or an error
            while (true) {
                if (self.current_chunk_size) |chunk_size| {
                    if (chunk_size == 0) {
                        // last chunk, we're done
                        break;
                    }

                    if (conn.buffered_bytes < self.parse_offset + chunk_size) {
                        // not enough data buffered yet
                        return null;
                    }

                    // consume chunk data, no need to parse it here
                    self.parse_offset += chunk_size + 2; // consume chunk data and \r\n
                    _ = reader.take(chunk_size + 2) catch unreachable;

                    // chunk must end with \r\n
                    if(buf[self.parse_offset - 2 ] != '\r' or buf[self.parse_offset - 1] != '\n') {
                        Logger.err("Invalid chunk ending", .{});
                        return Errors.InvalidChunkedEncoding;
                    }

                    self.current_chunk_size = null; // reset for next chunk
                } else {
                    if (reader.takeDelimiter('\n') catch null) |chunk_size_line| {
                        if (chunk_size_line.len < 2 or chunk_size_line[chunk_size_line.len - 1] != '\r') {
                            Logger.err("Invalid chunk size line ending {any}", .{chunk_size_line});
                            return Errors.InvalidChunkedEncoding;
                        }

                        const chunk_size_str = chunk_size_line[0 .. chunk_size_line.len - 1]; // exclude \r
                        self.current_chunk_size = std.fmt.parseInt(usize, chunk_size_str, 16) catch {
                            Logger.err("Invalid chunk size: {any}", .{chunk_size_str});
                            return Errors.InvalidChunkedEncoding;
                        };

                        self.parse_offset += chunk_size_line.len + 1; // consume chunk size line and \n
                    } else {
                        // not enough data buffered yet
                        return null;
                    }
                }
            }
        } else {
            if (self.body_size) |size| {
                if (conn.buffered_bytes < self.parse_offset + size) {
                    // not enough data buffered yet
                    return null;
                }

                // consume body data, no need to parse it here
                self.parse_offset += size;
            }
        }

        self.state = .complete;
        const body = buf[self.body_start.?..self.parse_offset];

        if (self.host == null) {
            return Errors.MissingHostHeader;
        }

        return Parser.ParseResult{
            .request = Request{
                .http = .{
                    .host = self.host.?,

                    .method = self.method.?,
                    .version = self.version.?,
                    .path = self.path.?,

                    .connection = self.connection,

                    .body = body,
                    .accepts = self.accepts,
                    .content_type = self.content_type,
                },
            },
            .consumed_bytes = self.parse_offset,
        };
    }

    fn resetState(self: *Http1Parser) void {
        self.parse_offset = 0;
        self.method = null;
        self.version = null;
        self.path = null;

        self.connection = .keep_alive;

        self.state = .request_line;
        self.body_size = null;
        self.transfer_encoding = .none;
    }

    inline fn parseHeader(self: *Http1Parser, name: []const u8, value: []const u8) Errors!void {
        const trimmed_name = std.mem.trim(u8, name, &std.ascii.whitespace);
        const trimmed_value = std.mem.trim(u8, value, &std.ascii.whitespace);

        if (std.ascii.eqlIgnoreCase(trimmed_name, "Host")) {
            if (self.host) |_| {
                return Errors.InvalidHostHeader; // multiple Host headers are not allowed
            }

            self.host = RequestHost.fromHostStr(trimmed_value) catch return Errors.InvalidHostHeader;
            return;
        }

        if (std.ascii.eqlIgnoreCase(trimmed_name, "Content-Length")) {
            const length = std.fmt.parseInt(usize, trimmed_value, 10) catch {
                Logger.err("Invalid Content-Length header value: {s}", .{trimmed_value});
                return;
            };
            self.body_size = length;

            return;
        }

        if (std.ascii.eqlIgnoreCase(trimmed_name, "Transfer-Encoding")) {
            if (std.ascii.eqlIgnoreCase(trimmed_value, "chunked")) {
                self.transfer_encoding = .chunked;
            }

            return;
        }

        if (std.ascii.eqlIgnoreCase(trimmed_name, "Content-Type")) {
            self.content_type = http.RequestContentType.fromString(trimmed_value) orelse {
                Logger.err("Unsupported Content-Type header value: {s}", .{trimmed_value});
                return;
            };
        }

        if (std.ascii.eqlIgnoreCase(trimmed_name, "Accept")) {
            self.accepts = trimmed_value;
            return;
        }

        if (std.ascii.eqlIgnoreCase(trimmed_name, "Connection")) {
            if (std.ascii.eqlIgnoreCase(trimmed_value, "close")) {
                self.connection = .close;
            }

            return;
        }
    }
};
