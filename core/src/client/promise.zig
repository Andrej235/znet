const std = @import("std");
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const Client = @import("client.zig").Client;

const State = enum {
    pending,
    fulfilled,
};

pub fn Promise(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: *std.Thread.Mutex = undefined,
        cond: *std.Thread.Condition = undefined,

        client: *Client,

        state: State = .pending,
        result: T = undefined,

        allocator: std.mem.Allocator,
        deserializer: *Deserializer,

        pub fn init(allocator: std.mem.Allocator, deserializer: *Deserializer, client: *Client) !*Self {
            const self = try allocator.create(Self);

            self.* = Self{
                .allocator = allocator,
                .deserializer = deserializer,
                .client = client,

                .mutex = &client.promise_mutex,
                .cond = &client.promise_condition,
            };

            return self;
        }

        pub fn destroyResult(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state != .fulfilled) return error.PromiseNotFulfilled;
            try self.deserializer.destroy(self.result);
        }

        pub fn deinit(self: *Self) void {
            const client = self.client; // avoids accessing self after deallocation
            client.promise_mutex.lock();
            defer client.promise_mutex.unlock();

            self.cond.broadcast();
            self.allocator.destroy(self);
        }

        pub fn await(self: *Self) T {
            if (self.state == .fulfilled) {
                return self.result;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state == .pending) {
                self.cond.wait(self.mutex);
            }

            return self.result;
        }

        pub fn resolve(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state != .pending) return;

            self.result = value;
            self.state = .fulfilled;

            self.cond.broadcast();
        }
    };
}
