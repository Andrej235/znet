const ConnectionReader = @import("../client_connection.zig").ConnectionReader;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.tls_parser);

pub const TlsParser = struct {
    pub fn init() TlsParser {
        return .{};
    }

    pub fn parse(self: *TlsParser, conn: *ConnectionReader) !?ConnectionReader.MessageReadResult {
        _ = self;
        _ = conn;
        Logger.err("TLS not implemented", .{});
        return error.Unimplemented;
    }
};
