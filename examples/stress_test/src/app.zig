const std = @import("std");
const z = @import("znet");

pub fn echo(message: z.Body([]const u8)) []const u8 {
    return message.value;
}

pub const App = z.App(
    .{z.Scope(
        .echo,
        .{
            z.Action(null, echo, .{}),
        },
        .{},
    )},
    .{
        .default_action_executor = .worker_pool,
    },
);
