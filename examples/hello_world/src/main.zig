const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{
        z.Scope(
            null,
            .{
                z.Action(null, hello, .{}),
                z.Action(.@"deeply-nested/{id}/{language}/post/{action}/edit", deeplyNestedPath, .{}),
            },
            .{},
        ),
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
    .{
        .default_action_executor = .io,
    },
);

pub fn main() !void {
    // const router = try App.compileRouter(std.heap.page_allocator);
    // router.print();

    // lookup(&router, "/deeply-nested/123/english/post/some-action/edit/", .GET);

    const server = try z.Server(App).init(std.heap.page_allocator, .{});
    
    try server.run(try std.net.Address.parseIp("127.0.0.1", 5000));
    server.join();
}

pub fn hello() bool {
    z.Logger.scoped(.action).info("Hello world!", .{});
    return true;
}

pub fn hello2(path: z.Path(struct { id: []const u8 })) bool {
    z.Logger.scoped(.action).info("Hello id {s}!", .{path.value.id});
    return true;
}

pub fn deeplyNestedPath(_: z.Path(struct { id: []const u8, language: []const u8, action: []const u8 })) bool {
    z.Logger.info("Hello from deeply nested path!", .{});
    return true;
}

fn lookup(router: *const z.Router, path: []const u8, method: z.HttpMethod) void {
    if (router.lookup(path, method)) |match| {
        z.Logger.info("Found match for path: {s}", .{match.action.path});
        var params = match.params;

        while (params.next()) |param| {
            z.Logger.info("Param: {s} = {s}", .{ param.name, param.value });
        }
    } else {
        z.Logger.err("No match for path: {s}", .{path});
    }
}
