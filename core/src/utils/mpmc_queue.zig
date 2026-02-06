const std = @import("std");

pub const QueueErrors = error{
    Closed,
};

/// A thread-safe multi-producer, multi-consumer queue implementation, uses a circular buffer.
/// The queue blocks producers when full and consumers when empty.
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

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.cond.broadcast(); // wake up all waiting threads so they can exit
        }

        pub fn push(self: *Self, job: T) QueueErrors!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == self.buf.len and !self.closed)
                self.cond.wait(&self.mutex);

            if (self.closed) {
                return QueueErrors.Closed;
            }

            self.buf[self.tail] = job;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;

            self.cond.signal();
        }

        pub fn pop(self: *Self) QueueErrors!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0 and !self.closed)
                self.cond.wait(&self.mutex);

            if (self.closed) {
                return QueueErrors.Closed;
            }

            const job = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;

            self.cond.signal();
            return job;
        }

        pub fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed or self.count == 0) {
                return null;
            }

            const job = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;

            self.cond.signal();
            return job;
        }

        pub fn peek(self: *Self) QueueErrors!*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0 and !self.closed)
                self.cond.wait(&self.mutex);

            if (self.closed) {
                return QueueErrors.Closed;
            }

            const job = &self.buf[self.head];
            return job;
        }

        pub fn tryPeek(self: *Self) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed or self.count == 0) {
                return null;
            }

            const job = &self.buf[self.head];
            return job;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.closed or self.count == 0;
        }

        pub fn isFull(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return !self.closed and self.count == self.buf.len;
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.closed;
        }
    };
}
