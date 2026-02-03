const std = @import("std");
const znet = @import("znet");

pub const EchoContract = struct {
    pub fn out(buffer: []const u8) void {
        std.debug.print("Received {} bytes\n", .{buffer.len});
    }
};
