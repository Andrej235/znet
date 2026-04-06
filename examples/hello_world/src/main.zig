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
    const router = App.compileRouter(std.heap.page_allocator);
    print(router.nodes);

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

fn print(nodes: []const z.Router.Node) void {
    printWithIndent(nodes, 0);
}

fn printWithIndent(nodes: []const z.Router.Node, indent: usize) void {
    for (nodes) |node| {
        const segment = if (node.segment.len > 0) node.segment else "/";

        var wrote = false;
        for (node.actions) |action| {
            if (action) |a| {
                wrote = true;

                for (0..indent) |_| {
                    std.debug.print("|  ", .{});
                }

                std.debug.print("-> {s} ({})\n", .{ segment, a.http_method });
            }
        }

        if (!wrote) {
            for (0..indent) |_| {
                std.debug.print("|  ", .{});
            }

            std.debug.print("-> {s}\n", .{segment});
        }

        if (node.children.items.len > 0) {
            printWithIndent(node.children.items, indent + 1);
        }
    }
}
