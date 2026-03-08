const std = @import("std");
const z = @import("znet");

const App = z.App(.{
    z.Scope(
        null,
        .{
            z.Action(null, healthCheck, .{}),
            z.Action(.echo, echo, .{}),
        },
        .{
            .default_action_executor = .io,
        },
    ),
    z.Scope(.user, .{
        z.Action(.register, helloWorld, .{}),
        z.Action(.login, helloWorld, .{}),
        z.Scope(.me, .{
            z.Action(null, hello, .{}),
            z.Action(.details, hello, .{}),
            z.Action(.@"details/profile_pic", hello, .{}),
            z.Action(.settings, hello, .{}),
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

fn echo(msg: z.Body([]const u8)) []const u8 {
    return msg.value;
}

fn helloWorld() !bool {
    std.debug.print("Hello, world!\n", .{});
    return true;
}

fn healthCheck() !bool {
    return true;
}
