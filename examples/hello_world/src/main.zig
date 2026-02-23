const std = @import("std");
const z = @import("znet");

const App = z.App(.{
    z.Scope("test", .{}, .{}),
    z.Scope("test", .{}, .{}),
}, .{});

pub fn main() !void {
    std.debug.print("Hello, world!\n", .{});

    const app: App = .{};
    _ = app;
}
