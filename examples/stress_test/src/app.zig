const std = @import("std");
const znet = @import("znet");

pub fn echo(message: []const u8) []const u8 {
    return message;
}

pub const App = znet.App(
    .{znet.Scope(
        "echo",
        .{
            znet.Action("", echo, .{}),
        },
        .{},
    )},
    .{},
);
