const std = @import("std");
const ConnectionReader = @import("../connection_reader.zig").ConnectionReader;

const Parser = @import("./parser.zig").Parser;
const Request = @import("../requests/request.zig").Request;
const Method = @import("../requests/http.zig").HttpMethod;
const Version = @import("../requests/http.zig").HttpVersion;

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

    method: ?Method = null,
    version: ?Version = null,
    path: ?[]const u8 = null,

    state: HttpState = .request_line,

    body_size: ?usize = null,
    transfer_encoding: TransferEncoding = .none,

    pub fn init() Http1Parser {
        return .{
            .parse_offset = 0,
        };
    }

    pub fn parse(self: *Http1Parser, conn: *ConnectionReader) !?Parser.ParseResult {
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
                    if (try line_reader.takeDelimiter(' ')) |method| {
                        if (try line_reader.takeDelimiter(' ')) |path| {
                            const version = line_reader.buffer[line_reader.seek..];

                            self.state = .headers;
                            self.method = Method.fromString(method) orelse {
                                Logger.err("Unsupported HTTP method: {s}", .{method});
                                // todo: implement arbitrary methods because spec supports them
                                return error.UnsupportedMethod;
                            };
                            self.path = path;
                            self.version = Version.fromString(version) orelse {
                                Logger.err("Unsupported HTTP version: {s}", .{version});
                                return error.UnsupportedVersion;
                            };
                        }
                    }
                },

                .headers => {
                    if (line.len == 2) {
                        // headers end with \r\n\r\n
                        self.state = .body;
                        break;
                    }

                    const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse {
                        Logger.err("Invalid HTTP header line (no colon found): {any}", .{line});
                        return error.InvalidHeaders;
                    };

                    const header_name = line[0..colon_index];
                    const header_value = std.mem.trim(u8, line[colon_index + 1 .. line.len - 2], &std.ascii.whitespace);

                    self.parseHeader(header_name, header_value);
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
            Logger.err("Chunked transfer encoding is not supported yet", .{});
            return error.UnsupportedTransferEncoding;
        }

        if (self.body_size) |size| {
            if (conn.buffered_bytes < self.parse_offset + size) {
                // not enough data buffered yet
                return null;
            }

            self.state = .complete;
            return Parser.ParseResult{
                .request = Request{
                    .http = .{
                        .method = self.method.?,
                        .version = self.version.?,
                        .path = self.path.?,
                        .body = buf[self.parse_offset..self.parse_offset + size],
                    },
                },
                .consumed_bytes = self.parse_offset + size,
            };
        }

        // no body
        self.state = .complete;
        return Parser.ParseResult{
            .request = Request{
                .http = .{
                    .method = self.method.?,
                    .version = self.version.?,
                    .path = self.path.?,
                    .body = null,
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
        self.state = .request_line;
        self.body_size = null;
        self.transfer_encoding = .none;
    }

    inline fn parseHeader(self: *Http1Parser, name: []const u8, value: []const u8) void {
        const trimmed_name = std.mem.trim(u8, name, &std.ascii.whitespace);

        if (std.mem.eql(u8, trimmed_name, "Content-Length")) {
            const length = std.fmt.parseInt(usize, value, 10) catch {
                Logger.err("Invalid Content-Length header value: {s}", .{value});
                return;
            };
            self.body_size = length;

            return;
        }

        if (std.mem.eql(u8, trimmed_name, "Transfer-Encoding")) {
            if (std.mem.eql(u8, std.mem.trim(u8, value, &std.ascii.whitespace), "chunked")) {
                self.transfer_encoding = .chunked;
            }

            return;
        }
    }
};
