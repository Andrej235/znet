const std = @import("std");

const Waker = @import("../waker/waker.zig");
const ParamIterator = @import("../app/router.zig").Router.ParamIterator;
const ContentType = @import("./http.zig").ContentType;

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    waker: Waker,

    body: ?[]const u8,
    body_content_type: ?ContentType,

    output_writer: *std.Io.Writer,
    accepts: ?[]const u8,

    param_iterator: ParamIterator,
    query: ?[]const u8,
};
