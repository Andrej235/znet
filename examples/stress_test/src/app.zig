const std = @import("std");
const z = @import("znet");

const SomeService = struct {
    pub fn hello(_: *const SomeService, message: z.Body([]const u8)) void {
        std.debug.print("message: {s}\n", .{message.value});
    }
};

pub fn echo(message: z.Body([]const u8), service: SomeService) []const u8 {
    service.hello(message);
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
