const std = @import("std");
const znet = @import("znet");

pub const MessageContract = struct {
    pub fn onRecieve(name: []const u8, message: []const u8) !void {
        var stdout_buf: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        var writer = &stdout_writer.interface;

        try writer.writeAll(name);
        try writer.writeAll(": ");
        try writer.writeAll(message);
        try writer.writeAll("\n");
        try writer.flush();
    }
};
