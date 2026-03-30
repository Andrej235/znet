const std = @import("std");
const znet = @import("znet");
const App = @import("app.zig").App;

pub const znet_options: znet.Options = .{
    .logger_type = .async,
};

const use_gpa = false;

pub fn main() !void {
    try znet.Logger.start();
    defer znet.Logger.shutdown(.graceful) catch unreachable;

    const TGpa = std.heap.GeneralPurposeAllocator(.{});
    var gpa: ?TGpa = if (comptime use_gpa) TGpa{} else null;
    defer {
        if (gpa) |*g| {
            if (g.deinit() == .leak) {
                znet.Logger.err("Memory leak detected", .{});
            } else {
                znet.Logger.info("Server shut down cleanly", .{});
            }
        }
    }

    const allocator = if (gpa) |*g| g.allocator() else std.heap.smp_allocator;

    const address = try std.net.Address.parseIp("127.0.0.1", 5001);

    const server = try znet.Server(App).init(
        allocator,
        .{
            .max_clients = 128,
            .client_read_buffer_size = 4096,
            .job_result_buffer_size = 4096,
            .worker_pool_size_per_io = 2,
        },
    );

    try server.run(address);

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var reader = &stdin_reader.interface;

    while (try reader.takeDelimiter('\n')) |message| {
        if (std.mem.eql(u8, message, "exit")) {
            try server.shutdown(.immediate);
            server.join();
            try server.deinit();

            znet.Logger.info("Exiting...", .{});
            break;
        }
    }
}
