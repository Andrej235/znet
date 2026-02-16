const std = @import("std");
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const Client = @import("client.zig").ClientInterface;
const PendingRequest = @import("pending_request.zig").PendingRequest;
const Timer = @import("../utils/timer.zig").Timer;

const AwaitMode = enum(u8) {
    borrow,
    release,
};

pub fn Promise(comptime T: type) type {
    return struct {
        const Self = @This();
        request: *PendingRequest,

        pub fn init(request: *PendingRequest) Self {
            return Self{
                .request = request,
            };
        }

        pub fn await(self: *Self, comptime await_mode: AwaitMode) PendingRequest.AwaitResult(T) {
            const result = self.request.await(T) catch |err| return err;

            if (comptime await_mode == .release)
                self.request.release();

            return result;
        }

        pub fn destroy(self: *Self, value: T) void {
            // const t= Timer.start("");
            self.request.client.deserializer.destroy(value) catch return;
            // t.end();
        }
    };
}
