const std = @import("std");
const ConnectionReader = @import("../client_connection.zig").ConnectionReader;

const Method = @import("../requests/http.zig").HttpMethod;
const Version = @import("../requests/http.zig").HttpVersion;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.http1_parser);

const HttpState = enum {
    request_line,
    headers,
    body,
};

pub const Http1Parser = struct {
    parse_offset: usize,

    method: ?Method = null,
    version: ?Version = null,
    path: ?[]const u8 = null,

    state: HttpState = .request_line,

    pub fn init() Http1Parser {
        return .{
            .parse_offset = 0,
        };
    }

    pub fn parse(self: *Http1Parser, conn: *ConnectionReader) !?ConnectionReader.MessageReadResult {
        const buf = conn.current_buffer[self.parse_offset..conn.buffered_bytes];
        var reader = std.io.Reader.fixed(buf);

        while (reader.takeDelimiterInclusive('\n') catch null) |line| {
            if (line[line.len - 2] != '\r') {
                // invalid line ending, http1 requires \r\n
                Logger.err("Invalid HTTP1 line ending", .{});
                return error.InvalidHeaders;
            }

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

                            Logger.debug("{} {s} ({})", .{ self.method.?, self.path.?, self.version.? });
                        }
                    }
                },

                .headers => {},

                .body => {},
            }
        }

        return error.Unimplemented;
    }
};
