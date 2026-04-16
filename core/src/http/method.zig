const std = @import("std");

pub const HttpMethod = enum(u4) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    HEAD = 4,
    OPTIONS = 5,
    CONNECT = 6,
    TRACE = 7,
    PATCH = 8,

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

    pub const count = @typeInfo(@This()).@"enum".fields.len;
};
