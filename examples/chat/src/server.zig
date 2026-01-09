const std = @import("std");
const znet = @import("znet");

pub fn main() !void {
    const server = try znet.Server.init(std.heap.page_allocator, .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try server.run(address);
}
