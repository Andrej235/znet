const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("server/echo-contract").EchoContract;

pub fn main() !void {
    var client = try znet.Client.init(std.heap.page_allocator, .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try client.connect(address);

    for (0..10_000) |_| {
        var message: [4000]u8 = [1]u8{'A'} ** 4000;
        const promise = try client.fetch(EchoContract.echo, .{&message});
        _ = promise.await();
    }

    std.debug.print("Done.\n", .{});
}
