const std = @import("std");
const znet = @import("znet");
const EchoContract = @import("server/echo_contract").EchoContract;

const num_workers = 4;
const benchmark_seconds = 5;
const warmup_requests = 100;

var running = std.atomic.Value(bool).init(true);
var ready_workers = std.atomic.Value(usize).init(0);
var start_signal = std.atomic.Value(bool).init(false);
var total_requests = std.atomic.Value(u64).init(0);

const message_size = 1;
var message: [message_size]u8 = [_]u8{'A'} ** message_size;

pub fn main() !void {
    var threads: [num_workers]std.Thread = undefined;

    inline for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{});
    }

    // Wait until all workers report ready
    while (ready_workers.load(.acquire) != num_workers) {
        std.atomic.spinLoopHint();
    }

    // Start benchmark
    const start = std.time.nanoTimestamp();
    start_signal.store(true, .release);

    std.Thread.sleep(benchmark_seconds * std.time.ns_per_s);
    running.store(false, .release);

    inline for (threads) |t| t.join();

    const end = std.time.nanoTimestamp();

    const elapsed_s =
        @as(f64, @floatFromInt(end - start)) / std.time.ns_per_s;
    const total = total_requests.load(.acquire);
    const rps = @as(f64, @floatFromInt(total)) / elapsed_s;

    std.debug.print(
        \\Duration: {d:.2}s
        \\Total requests: {}
        \\Average RPS: {d:.0}
        \\
    , .{ elapsed_s, total, rps });
}

fn worker() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();

    var client = try znet.Client.init(gpa.allocator(), .{});
    defer client.deinit() catch {};

    const address = try std.net.Address.parseIp("127.0.0.1", 5000);
    try client.connect(address);

    // ---- Warmup ----
    for (0..warmup_requests) |_| {
        const p = try client.fetch(EchoContract.echo, .{&message});
        _ = p.await();
        try p.destroyResult();
        p.deinit();
    }

    // Signal readiness
    _ = ready_workers.fetchAdd(1, .release);

    // Barrier: wait for benchmark start
    while (!start_signal.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    // ---- Timed benchmark ----
    while (running.load(.acquire)) {
        const p = try client.fetch(EchoContract.echo, .{&message});
        _ = p.await();
        try p.destroyResult();
        p.deinit();

        _ = total_requests.fetchAdd(1, .monotonic);
    }
}
