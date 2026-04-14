const std = @import("std");

const http = @import("../http/http.zig");
const ParsedHost = @import("../app/host/parsed_host.zig").ParsedHost;

pub const HttpRequest = struct {
    host: ParsedHost,
    path: []const u8,
    method: http.Method,
    version: http.Version,
    connection: http.Connection,

    body: ?[]const u8,
    content_type: ?http.RequestContentType,
    accepts: ?[]const u8,
};
