const std = @import("std");

pub const QueueErrors = error{
    QueueFull,
};

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        count: usize,
        buffer: []T,
        head: std.atomic.Value(usize) align(64) = .init(0),
        tail: std.atomic.Value(usize) align(64) = .init(0),

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            if (count <= 0) {
                return error.InvalidCount;
            }

            if ((count & (count - 1)) != 0) {
                return error.CountMustBePowerOfTwo;
            }

            const buffer = try allocator.alloc(T, count);

            return Self{
                .count = count,
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn tryPush(self: *Self, value: T) QueueErrors!void {
            const head = self.head.load(.monotonic);

            // queue full
            if (self.tail.load(.acquire) + self.count == head)
                return QueueErrors.QueueFull;

            self.buffer[head & (self.count - 1)] = value;
            self.head.store(head + 1, .release);
        }

        pub fn tryPop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);

            // queue empty
            if (self.head.load(.acquire) == tail)
                return null;

            const value = self.buffer[tail & (self.count - 1)];
            self.tail.store(tail + 1, .release);
            return value;
        }

        pub fn tryPeek(self: *Self) ?*T {
            const tail = self.tail.load(.monotonic);

            // queue empty
            if (self.head.load(.acquire) == tail)
                return null;

            return &self.buffer[tail & (self.count - 1)];
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        pub fn isFull(self: *Self) bool {
            return self.tail.load(.acquire) + self.count == self.head.load(.acquire);
        }
    };
}

const testing = std.testing;

test "single threaded" {
    var queue = Queue(u32).init(std.heap.page_allocator, 4) catch unreachable;
    defer queue.deinit(std.heap.page_allocator);

    try queue.tryPush(1);
    try queue.tryPush(2);
    try queue.tryPush(3);
    try queue.tryPush(4);

    try testing.expectError(QueueErrors.QueueFull, queue.tryPush(5));

    try testing.expectEqual(1, queue.tryPop());
    try testing.expectEqual(2, queue.tryPop());
    try testing.expectEqual(3, queue.tryPop());
    try testing.expectEqual(4, queue.tryPop());

    try testing.expectEqual(null, queue.tryPop());
}

test "1 producer, 1 consumer" {
    var queue = Queue(u32).init(std.heap.page_allocator, 4) catch unreachable;
    defer queue.deinit(std.heap.page_allocator);

    const producer = std.Thread.spawn(.{}, producerFn, .{ &queue, 1024 }) catch unreachable;
    const consumer = std.Thread.spawn(.{}, consumerFn, .{ &queue, 1024, 1 }) catch unreachable;

    producer.join();
    consumer.join();

    try testing.expectEqual(true, queue.isEmpty());
}

fn producerFn(queue: *Queue(u32), comptime iteration_count: u32) !void {
    const start = std.time.milliTimestamp();
    const max_duration = 1000; // 1 second

    var i: u32 = 0;
    while (i < iteration_count) {
        queue.tryPush(i) catch {
            if (std.time.milliTimestamp() - start > max_duration) {
                return error.Timeout;
            }
            continue;
        };
        i += 1;
    }
}

fn consumerFn(queue: *Queue(u32), comptime total_iterations: u32, comptime consumer_count: u32) !void {
    const start = std.time.milliTimestamp();
    const max_duration = 1000; // 1 second

    if (comptime total_iterations % consumer_count != 0) {
        @compileError("iteration_count must be divisible by consumer_count");
    }

    var count: usize = 0;
    while (count < comptime total_iterations / consumer_count) {
        if (queue.tryPop()) |item| {
            _ = item;
            count += 1;
        } else {
            if (std.time.milliTimestamp() - start > max_duration) {
                return error.Timeout;
            }
        }
    }
}
