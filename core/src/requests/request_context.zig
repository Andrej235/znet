const std = @import("std");
const http = @import("../http/http.zig");

const Waker = @import("../waker/waker.zig");
const ParamIterator = @import("../app/router.zig").Router.ParamIterator;

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    waker: Waker,

    body: ?[]const u8,
    body_content_type: ?http.RequestContentType,

    output_writer: *std.Io.Writer,
    accepts: ?[]const u8,
    connection: http.Connection,

    param_iterator: ParamIterator,
    query: ?[]const u8,
};
