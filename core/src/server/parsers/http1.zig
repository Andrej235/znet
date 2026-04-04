const std = @import("std");
const ConnectionReader = @import("../client_connection.zig").ConnectionReader;

const Method = @import("../requests/http.zig").HttpMethod;
const Version = @import("../requests/http.zig").HttpVersion;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.http1_parser);

pub const Http1Parser = struct {
    pub fn init() Http1Parser {
        return .{
            .parse_offset = 0,
        };
    }

    pub fn parse(self: *Http1Parser, conn: *ConnectionReader) !?ConnectionReader.MessageReadResult {
        _ = conn;
        _ = self;
        Logger.info("Parsing HTTP/1.x message");
        return error.Unimplemented;
    }
};
