const std = @import("std");

pub const MessageContract = struct {
    pub fn receiveMessage(sender_name: []const u8, message: []const u8) void {
        std.debug.print(">{s}: {s}\n", .{ sender_name, message });
    }
};
