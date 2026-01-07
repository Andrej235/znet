const std = @import("std");
const zNet = @import("znet");

pub fn main() !void {
    std.debug.print("Hello from echo\n", .{});

    zNet.hello();
}
