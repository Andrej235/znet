const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("server/echo-contract").EchoContract;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("MEMORY LEAK DETECTED\n", .{});
        } else {
            std.debug.print("Client shut down cleanly\n", .{});
        }
    }

    var client = try znet.Client.init(gpa.allocator(), .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try client.connect(address);

    for (0..1_000) |_| {
        var message: [4000]u8 = [1]u8{'A'} ** 4000;
        const promise = try client.fetch(EchoContract.echo, .{&message});
        _ = promise.await();
        try promise.destroyResult();
        promise.deinit();
    }

    client.deinit();

    std.debug.print("Done.\n", .{});
}
