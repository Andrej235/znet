const std = @import("std");
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const Client = @import("client.zig").Client;
const PendingRequest = @import("pending_request.zig").PendingRequest;

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

        pub fn await(self: *Self, comptime await_mode: AwaitMode) T {
            const opaque_result = self.request.await() catch unreachable; // todo: handle promise rejection

            const result: Deserializer.SafeAllocResult(T) = @ptrCast(@alignCast(opaque_result));

            const info = @typeInfo(T);
            if (info == .pointer and info.pointer.size == .one) {
                if (comptime await_mode == .release)
                    self.request.release();

                return result;
            }

            if (comptime await_mode == .release) {
                const result_val = result.*;

                self.request.release();
                self.request.client.deserializer.allocator.destroy(result);
                return result_val;
            }

            return result.*;
        }

        pub fn destroy(self: *Self, value: T) void {
            self.request.client.deserializer.destroy(value) catch return;
        }
    };
}
