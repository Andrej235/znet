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
        if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
        if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
        if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
        if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
        if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
        if (std.ascii.eqlIgnoreCase(s, "OPTIONS")) return .OPTIONS;
        if (std.ascii.eqlIgnoreCase(s, "CONNECT")) return .CONNECT;
        if (std.ascii.eqlIgnoreCase(s, "TRACE")) return .TRACE;
        if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .PATCH;
        return null;
    }

    pub fn toString(self: HttpMethod) []const u8 {
        return @tagName(self);
    }

    pub const count = @typeInfo(@This()).@"enum".fields.len;
};
