const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("server/echo_contract").EchoContract;

pub fn main() !void {
    const num_workers = 2; // bigger number just doesn't work (server can't handle it? ), todo: fix
    var threads: [num_workers]std.Thread = undefined;

    // Spawn threads
    inline for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{});
    }

    // Wait for all threads to finish
    inline for (threads) |thread| {
        thread.join();
    }

    std.debug.print("All workers finished\n", .{});
}

const message_size = 4000;
var message: [message_size]u8 = [1]u8{'A'} ** message_size;

fn worker() !void {
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
        const promise = try client.fetch(EchoContract.echo, .{&message});
        const res = promise.await();

        if (!std.mem.eql(u8, &message, res))
            std.debug.print("----- Incorrect response! -----\n", .{});

        try promise.destroyResult();
        promise.deinit();
    }

    client.deinit();
}
