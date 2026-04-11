const Parser = @import("./parser.zig").Parser;
const ConnectionReader = @import("../connection_reader.zig").ConnectionReader;
const Request = @import("../../requests/request.zig").Request;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.tls_parser);

pub const TlsParser = struct {
    pub fn init() TlsParser {
        return .{};
    }

    pub fn parse(self: *TlsParser, conn: *ConnectionReader) !?Parser.ParseResult {
        _ = self;
        _ = conn;
        Logger.err("TLS not implemented", .{});
        return error.Unimplemented;
    }
};
