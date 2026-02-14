const std = @import("std");

pub const QueueErrors = error{
    QueueFull,
};

/// A multi-producer, single-consumer queue implementation, uses a circular buffer.
/// Producers side is thread-safe, consumer side is not
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        closed: bool = false,

        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        pub fn init(buffer: []T) !Self {
            return Self{
                .buf = buffer,
            };
        }

        pub fn tryPush(self: *Self, job: T) QueueErrors!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == self.buf.len)
                return QueueErrors.QueueFull;

            self.buf[self.tail] = job;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;
        }

        pub fn tryPop(self: *Self) ?T {
            if (self.count == 0) {
                return null;
            }

            const job = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;

            self.cond.signal();
            return job;
        }

        pub fn tryPeek(self: *Self) ?*T {
            if (self.count == 0) {
                return null;
            }

            const job = &self.buf[self.head];
            return job;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.closed or self.count == 0;
        }

        pub fn isFull(self: *Self) bool {
            return !self.closed and self.count == self.buf.len;
        }
    };
}
