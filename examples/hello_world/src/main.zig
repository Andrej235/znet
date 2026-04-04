const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{
        z.Scope(
            null,
            .{
                z.Action(null, hello, .{}),
            },
            .{},
        ),
    },
    .{},
);

pub fn main() !void {
    const server = try z.Server(App).init(std.heap.page_allocator, .{});

    try server.run(try std.net.Address.parseIp("127.0.0.1", 5000));
    server.join();
}

pub fn hello() bool {
    z.Logger.info("Hello world!", .{});
    return true;
}
