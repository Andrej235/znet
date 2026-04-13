const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{
        z.Host("example.com", .{z.Scope(null, .{z.Action(null, helloFromExample, .{})}, .{})}, .{}),
        z.Host(
            null,
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
                                z.Action(.@"{id}/q", helloWithQuery, .{}),
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
                                z.Action(null, post, .{ .http_method = .POST }),
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
        ),
        z.Host("api.example.com", .{z.Scope(null, .{z.Action(null, helloFromExampleApi, .{})}, .{})}, .{}),
    },
    .{
        .default_action_executor = .io,
    },
);

pub fn main() !void {
    const server = try z.Server(App).init(std.heap.page_allocator, .{});

    try server.run(try std.net.Address.parseIp("127.0.0.1", 5000));
    server.join();
}

pub fn helloFromExample() struct { message: []const u8 } {
    return .{ .message = "Hello from example.com!" };
}

pub fn helloFromExampleApi() struct { message: []const u8 } {
    return .{ .message = "Hello from api.example.com!" };
}

pub fn hello() bool {
    z.Logger.scoped(.action).info("Hello world!", .{});
    return true;
}

pub fn helloWithQuery(
    path: z.Path(struct { id: u8 }),
    query: z.Query(struct { search: ?[]const u8, some_needed_val: u32, numeric: f64 }),
) bool {
    z.Logger.scoped(.action).info("Hello id {}! Search query: {?s}, Required: {}, Numeric: {}", .{ path.value.id, query.value.search, query.value.some_needed_val, query.value.numeric });
    return true;
}

pub fn hello2(path: z.Path(struct { id: []const u8 })) bool {
    z.Logger.scoped(.action).info("Hello id {s}!", .{path.value.id});
    return true;
}

pub fn deeplyNestedPath(path: z.Path(struct { id: u32, language: []const u8, action: []const u8 })) struct {
    message: []const u8,
    success: bool,
    some_value: ?u32,
} {
    z.Logger.info("Hello from deeply nested path! Passed params: {} | {s} | {s}", .{ path.value.id, path.value.language, path.value.action });
    return .{
        .message = "Hello from deeply nested path!",
        .success = true,
        .some_value = path.value.id * 2,
    };
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

fn post(body: z.Body(struct { message: []const u8 }), allocator: std.mem.Allocator) struct { msg: ?[]const u8, success: bool } {
    const msg = allocator.alloc(u8, body.value.message.len + 6) catch {
        z.Logger.err("Failed to allocate memory for response message", .{});
        return .{ .success = false, .msg = null };
    };

    @memcpy(msg[0..6], "hello ");
    @memcpy(msg[6..], body.value.message);

    z.Logger.info("Hi there, {s}", .{msg});
    return .{ .success = true, .msg = msg };
}
