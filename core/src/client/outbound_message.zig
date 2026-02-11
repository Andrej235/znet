const std = @import("std");
const MessageHeaders = @import("../message_headers/message_headers.zig").MessageHeaders;

pub const OutboundMessage = struct {
    buffer_idx: u32,
    data: []const u8,
};
