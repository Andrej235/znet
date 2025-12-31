const std = @import("std");

/// A thread-safe multi-producer, multi-consumer queue implementation, uses a circular buffer.
/// The queue blocks producers when full and consumers when empty.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        pub fn init(buffer: []T) !Self {
            return Self{
                .buf = buffer,
            };
        }

        pub fn push(self: *Self, job: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == self.buf.len)
                self.cond.wait(&self.mutex);

            self.buf[self.tail] = job;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;

            self.cond.signal();
        }

        pub fn pop(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0)
                self.cond.wait(&self.mutex);

            const job = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;

            self.cond.signal();
            return job;
        }
    };
}
