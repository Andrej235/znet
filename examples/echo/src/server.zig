const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("contracts/server/echo_contract.zig").EchoContract;
const Schema = znet.Schema(.{ .server_contracts = &.{EchoContract} });

pub fn main() !void {
    var server = try znet.Server(Schema).init(std.heap.page_allocator, .{
        .max_clients = 2048,
    });

    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try server.run(address);
    server.join();
}
