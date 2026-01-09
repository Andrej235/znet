const std = @import("std");
const znet = @import("znet");
const TestContract = @import("server/test-contract").TestContract;

pub const MessageContract = struct {
    pub fn receiveMessage(sender_name: []const u8, message: []const u8) !void {
        std.debug.print(">{s}: {s}\n", .{ sender_name, message });
    }
};
