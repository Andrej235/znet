const std = @import("std");
const z = @import("znet");

const App = z.App(.{
    z.Scope("user", .{
        z.Action("register", helloWorld, .{}),
        z.Action("login", helloWorld, .{}),
        z.Scope("me", .{
            z.Action("details", hello, .{}),
            z.Action("settings", hello, .{}),
        }, .{}),
    }, .{}),
}, .{});

pub fn main() !void {
    const call_table = comptime App.compileServerCallTable();
    for (call_table) |scope| {
        for (scope) |action| {
            std.debug.print("{s}\n", .{action.path});
        }
    }

    const app: App = .{};
    _ = app;
}

fn hello() !bool {
    std.debug.print("Hello from the handler!\n", .{});
    return true;
}

fn helloWorld() !bool {
    std.debug.print("Hello, world!\n", .{});
    return true;
}
