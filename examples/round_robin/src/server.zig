const std = @import("std");
const znet = @import("znet");
const role = @import("znet/role").role;

var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("MEMORY LEAK DETECTED\n", .{});
        } else {
            std.debug.print("Server shut down cleanly\n", .{});
        }
    }

    var server = try znet.Server.init(gpa.allocator(), .{
        .max_clients = 8,
        .worker_threads = 8,
        .client_read_buffer_size = 1024,
        .job_result_buffer_size = 1024 * 1024 * 1024,
        .max_broadcast_jobs_in_queue = 8,
        .max_jobs_in_queue = 8,
    });

    _ = try std.Thread.spawn(.{}, listenerThread, .{});

    const address = try std.net.Address.parseIp("192.168.1.100", 5000);
    try server.runUntil(address, &running);
    try server.deinit();
}

pub fn listenerThread() !void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var reader = &stdin_reader.interface;

    while (try reader.takeDelimiter('\n')) |message| {
        if (std.mem.eql(u8, message, "exit")) {
            running.store(false, .release);
            std.debug.print("Exit\n", .{});
            break;
        }
    }
}
