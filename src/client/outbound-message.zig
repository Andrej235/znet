const std = @import("std");
const MessageHeaders = @import("../message-headers/message-headers.zig").MessageHeaders;

pub const OutboundMessage = struct {
    request_id: u32,
    // used to allocate args
    allocator: std.mem.Allocator,
    serialize: *const fn (message: OutboundMessage, writer: *std.io.Writer) anyerror!MessageHeaders,
    promise: *anyopaque,
    args: *anyopaque,
};
