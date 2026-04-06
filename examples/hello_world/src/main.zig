const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{
        z.Scope(
            .api,
            .{
                z.Scope(
                    .users,
                    .{
                        z.Action(null, hello, .{}),
                        z.Action(.@"{id}", hello2, .{}),
                        z.Action(.all, hello, .{}),
                        z.Action(.@"all/preview", hello, .{}),
                        z.Action(.register, hello, .{}),
                        z.Action(.login, hello, .{}),
                    },
                    .{},
                ),
                z.Scope(
                    .posts,
                    .{
                        z.Action(null, hello, .{ .http_method = .POST }),
                        z.Action(.all, hello, .{}),
                        z.Action(.@"all/preview", hello, .{}),
                        z.Action(.@"{id}", hello2, .{}),
                        z.Action(.@"{id}/preview", hello2, .{}),
                    },
                    .{},
                ),
            },
            .{},
        ),
    },
    .{},
);

pub fn main() !void {
    const router = try App.compileRouter(std.heap.page_allocator);
    router.print();

    const server = try z.Server(App).init(std.heap.page_allocator, .{});

    try server.run(try std.net.Address.parseIp("127.0.0.1", 5000));
    server.join();
}

pub fn hello() bool {
    z.Logger.info("Hello world!", .{});
    return true;
}

pub fn hello2(_: z.Path(struct { id: u8 })) bool {
    z.Logger.info("Hello world with id!", .{});
    return true;
}
