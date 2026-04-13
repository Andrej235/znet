const std = @import("std");

const http = @import("../http/http.zig");

pub const HttpRequest = struct {
    host: ?[]const u8,
    path: []const u8,
    method: http.Method,
    version: http.Version,
    connection: http.Connection,

    body: ?[]const u8,
    content_type: ?http.RequestContentType,
    accepts: ?[]const u8,
};
