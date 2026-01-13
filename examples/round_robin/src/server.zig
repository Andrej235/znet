const std = @import("std");
const znet = @import("znet");
const role = @import("znet/role").role;

pub fn main() !void {
    var server = try znet.Server.init(std.heap.page_allocator, .{
        .max_clients = 2,
        .worker_threads = 2,
        .client_read_buffer_size = 1024 * 1024,
        .job_result_buffer_size = 1024 * 1024 * 1024,
        .max_broadcast_jobs_in_queue = 2,
        .max_jobs_in_queue = 2,
    });

    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try server.run(address);
}
