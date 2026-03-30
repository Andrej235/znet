const std = @import("std");

pub const Semaphore = struct {
    count: std.atomic.Value(u32) = .init(0),

    pub fn init(initial: u32) Semaphore {
        return Semaphore{
            .count = std.atomic.Value(u32).init(initial),
        };
    }

    pub fn acquire(self: *Semaphore) void {
        while (true) {
            const current = self.count.load(.acquire);

            if (current > 0) {
                if (self.count.cmpxchgWeak(
                    current,
                    current - 1,
                    .acq_rel,
                    .acquire,
                ) == null)
                    return; // acquired

                continue;
            }

            // sleep while count == 0
            std.Thread.Futex.wait(&self.count, 0);
        }
    }

    pub fn tryAcquire(self: *Semaphore) bool {
        var current = self.count.load(.acquire);

        while (current > 0) {
            if (self.count.cmpxchgWeak(
                current,
                current - 1,
                .acq_rel,
                .acquire,
            ) == null)
                return true; // acquired

            current = self.count.load(.acquire);
        }

        return false;
    }

    pub fn release(self: *Semaphore) void {
        _ = self.count.fetchAdd(1, .acq_rel);
        std.Thread.Futex.wake(&self.count, 1);
    }

    pub fn batchRelease(self: *Semaphore, count: u32) void {
        _ = self.count.fetchAdd(count, .acq_rel);
        std.Thread.Futex.wake(&self.count, count);
    }
};
