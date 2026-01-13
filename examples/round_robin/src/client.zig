const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("server/echo_contract").EchoContract;

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);

    var client_1 = try znet.Client.init(std.heap.page_allocator, .{
        .read_buffer_size = 1024 * 1024 * 1024,
        .write_buffer_size = 1024 * 1024,
    });
    try client_1.connect(address);

    var client_2 = try znet.Client.init(std.heap.page_allocator, .{
        .read_buffer_size = 1024 * 1024,
        .write_buffer_size = 1024 * 1024,
    });
    try client_2.connect(address);

    const promise_1 = try client_1.fetch(EchoContract.sendGig, .{});
    // const promise_1 = try client_1.fetch(EchoContract.sendNBytes, .{1024 * 1024 * 1024 - 32});
    // const promise_2 = try client_2.fetch(EchoContract., .{ "B", 0.1 });

    // const res_2 = promise_2.await();
    // std.debug.print("Client 2 received: {} bytes\n", .{res_2.len});

    const res_1 = promise_1.await();
    std.debug.print("Client 1 received: {} bytes\n", .{res_1.len});
}
