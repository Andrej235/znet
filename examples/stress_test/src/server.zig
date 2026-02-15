const std = @import("std");
const znet = @import("znet");
const Schema = @import("schema.zig").Schema;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("MEMORY LEAK DETECTED\n", .{});
        } else {
            std.debug.print("Server shut down cleanly\n", .{});
        }
    }

    const address = try std.net.Address.parseIp("127.0.0.1", 5000);

    const server = try znet.Server.run(
        std.heap.smp_allocator,
        .{
            .max_clients = 128,
            .client_read_buffer_size = 4096,
            .job_result_buffer_size = 4096,
        },
        Schema,
        address,
    );

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var reader = &stdin_reader.interface;

    while (try reader.takeDelimiter('\n')) |message| {
        if (std.mem.eql(u8, message, "exit")) {
            try server.deinit();
            std.debug.print("Exit\n", .{});
            break;
        }
    }
}
