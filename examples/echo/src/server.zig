const std = @import("std");
const znet = @import("znet");
const role = @import("znet/role").role;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try znet.Server.init(allocator, .{
        .max_clients = 2048,
    });

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    std.debug.print("{}\n", .{role});

    try server.run(address);
}
