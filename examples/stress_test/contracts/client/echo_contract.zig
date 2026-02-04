const std = @import("std");

pub const EchoContract = struct {
    pub fn echo(message: []const u8) !void {
        // std.debug.print("<-- Broadcast\n", .{});
        _ = message;
    }
};
