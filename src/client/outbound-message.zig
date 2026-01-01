const std = @import("std");
const MessageHeaders = @import("../message-headers/message-headers.zig").MessageHeaders;

pub const OutboundMessage = struct {
    serialize: *const fn (writer: *std.io.Writer) anyerror!MessageHeaders,
    promise: *anyopaque,
};
