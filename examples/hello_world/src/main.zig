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
                        z.Action(.@"hello/{id}", helloWithQuery, .{}),
                    },
                    .{},
                ),
                z.Scope(
                    .posts,
                    .{
                        z.Action(null, post, .{ .http_method = .POST }),
                        z.Action(.@"{id}", hello2, .{}),
                    },
                    .{},
                ),
            },
            .{},
        ),
        z.Host("*.example.com", .{z.Scope(null, .{z.Action(null, helloFromExampleWildcard, .{})}, .{})}, .{}),
        z.Host("api.example.com", .{z.Scope(null, .{z.Action(null, helloFromExampleApi, .{})}, .{})}, .{}),
    },
    .{
        .default_action_executor = .worker_pool,
    },
);

pub fn main() !void {
    const server = try z.Server(App).init(std.heap.page_allocator, .{});

    try server.run(try std.net.Address.parseIp("127.0.0.1", 5000));
    server.join();
}

fn helloFromExample() struct { message: []const u8 } {
    return .{ .message = "Hello from example.com!" };
}

fn helloFromExampleApi() struct { message: []const u8 } {
    return .{ .message = "Hello from api.example.com!" };
}

fn helloFromExampleWildcard() struct { message: []const u8 } {
    return .{ .message = "Hello from *.example.com!" };
}

fn hello() bool {
    z.Logger.scoped(.action).info("Hello world!", .{});
    return true;
}

fn helloWithQuery(
    path: z.Path(struct { id: u8 }),
    query: z.Query(struct { search: ?[]const u8, some_needed_val: u32, numeric: f64 }),
) bool {
    z.Logger.scoped(.action).info("Hello id {}! Search query: {?s}, Required: {}, Numeric: {}", .{ path.value.id, query.value.search, query.value.some_needed_val, query.value.numeric });
    return true;
}

fn hello2(path: z.Path(struct { id: []const u8 })) bool {
    z.Logger.scoped(.action).info("Hello id {s}!", .{path.value.id});
    return true;
}

fn deeplyNestedPath(path: z.Path(struct { id: u32, language: []const u8, action: []const u8 })) struct {
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
