const std = @import("std");
const Role = @import("role.zig").Role;

pub fn App(comptime role: Role) type {
    return struct {
        pub fn run() !void {
            std.debug.print("Starting {s}\n", .{
                if (role == .server) "server" else "client",
            });

            if (role == .server) {
                try serverMain();
            } else {
                try clientMain();
            }
        }

        fn serverMain() !void {
            std.debug.print("Server main\n", .{});
        }

        fn clientMain() !void {
            std.debug.print("Client main\n", .{});
        }
    };
}
