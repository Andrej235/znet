const std = @import("std");
const znet = @import("znet");
const role = @import("znet/role").role;

pub fn main() !void {
    var server = try znet.Server.init(std.heap.page_allocator, .{
        .max_clients = 2048,
    });

    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    std.debug.print("{}\n", .{role});

    try server.run(address);
}
