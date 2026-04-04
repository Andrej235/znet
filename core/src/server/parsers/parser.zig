const std = @import("std");
const ConnectionReader = @import("../client_connection.zig").ConnectionReader;

const Http1Parser = @import("http1.zig").Http1Parser;
const TlsParser = @import("tls.zig").TlsParser;

pub const Parser = union(enum) {
    http1: Http1Parser,
    tls: TlsParser,

    pub fn parse(self: *Parser, conn: *ConnectionReader) !?ConnectionReader.MessageReadResult {
        return switch (self.*) {
            .http1 => self.http1.parse(conn),
            .tls => self.tls.parse(conn),
        };
    }
};
