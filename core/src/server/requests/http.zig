const std = @import("std");

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    version: HttpVersion,
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    CONNECT,
    TRACE,
    PATCH,

    pub fn fromString(s: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, s, "TRACE")) return .TRACE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        return null;
    }
};

pub const HttpVersion = enum {
    Http10,
    Http11,
    Http2,

    pub fn fromString(s: []const u8) ?HttpVersion {
        if (std.mem.eql(u8, s, "HTTP/1.0")) return .Http10;
        if (std.mem.eql(u8, s, "HTTP/1.1")) return .Http11;
        if (std.mem.eql(u8, s, "HTTP/2.0")) return .Http2;
        return null;
    }
};
