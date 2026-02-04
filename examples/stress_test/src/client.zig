const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("server/echo_contract").EchoContract;

pub fn main() !void {
    const num_workers = 2; // bigger numbers just don't work (server can't handle it? ), todo: fix ||| this is caused by broadcasting somehow
    var threads: [num_workers]std.Thread = undefined;

    // Spawn threads
    const start = std.time.nanoTimestamp();
    inline for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{i});
    }

    // Wait for all threads to finish
    inline for (threads) |thread| {
        thread.join();
    }

    const end = std.time.nanoTimestamp();
    std.debug.print("All workers finished in {}s\n", .{@as(f128, @floatFromInt(end - start)) / std.time.ns_per_s});
}

const message_size = 1;
var message: [message_size]u8 = [1]u8{'A'} ** message_size;

fn worker(idx: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("MEMORY LEAK DETECTED IN {}\n", .{idx});
        } else {
            std.debug.print("Client {} shut down cleanly\n", .{idx});
        }
    }

    var client = try znet.Client.init(gpa.allocator(), .{});
    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try client.connect(address);

    for (0..50) |_| {
        // std.debug.print("[{}] sending a request\n", .{idx});
        // std.debug.print("---> Request\n", .{});

        const promise = try client.fetch(EchoContract.echo, .{&message});
        const res = promise.await();

        if (!std.mem.eql(u8, &message, res))
            std.debug.print("----- Incorrect response! -----\n", .{});

        // std.debug.print("<-- Response\n", .{});
        try promise.destroyResult();
        promise.deinit();
    }

    client.deinit();
}
