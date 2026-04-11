const std = @import("std");

const http = @import("../http/http.zig");

pub const HttpRequest = struct {
    method: http.Method,
    path: []const u8,
    version: http.Version,
    connection: http.Connection,

    body: ?[]const u8,
    content_type: ?http.RequestContentType,
    accepts: ?[]const u8,
};
