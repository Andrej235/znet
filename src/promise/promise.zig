const std = @import("std");

const State = enum {
    pending,
    fulfilled,
};

pub fn Promise(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        state: State = .pending,
        result: T = undefined,

        pub fn await(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state == .pending) {
                self.cond.wait(&self.mutex);
            }

            return switch (self.result) {
                .ok => |value| value,
                .err => |err| err,
            };
        }

        pub fn resolve(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state != .pending) return;

            self.result = .{ .ok = value };
            self.state = .fulfilled;

            self.cond.signal();
        }
    };
}
