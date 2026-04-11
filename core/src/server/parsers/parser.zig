const std = @import("std");
const ConnectionReader = @import("../connection_reader.zig").ConnectionReader;
const Request = @import("../../requests/request.zig").Request;

const Http1Parser = @import("http1.zig").Http1Parser;
const TlsParser = @import("tls.zig").TlsParser;

pub const Parser = union(enum) {
    pub const ParseResult = struct {
        request: Request,
        consumed_bytes: usize,
    };

    http1: Http1Parser,
    tls: TlsParser,

    pub fn parse(self: *Parser, conn: *ConnectionReader) !?ParseResult {
        return switch (self.*) {
            .http1 => self.http1.parse(conn),
            .tls => self.tls.parse(conn),
        };
    }
};
