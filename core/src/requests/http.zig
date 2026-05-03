const std = @import("std");

const http = @import("../http/http.zig");
const RequestHost = @import("../app/host/request_host.zig").RequestHost;

pub const HttpRequest = struct {
    host: RequestHost,
    path: []const u8,
    method: http.Method,
    version: http.Version,
    connection: http.Connection,

    body: ?[]const u8,
    chunked: bool,
    content_type: ?http.RequestContentType,

    // raw header values for content encoding and accepts, which will be parsed later when needed due to their complexity and potential for multiple values
    content_encoding: ?[]const u8,
    accepts: ?[]const u8,
};
