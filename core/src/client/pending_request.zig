const std = @import("std");
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const Client = @import("client.zig").Client;

const State = enum(u8) {
    free,
    pending,
    fulfilled,
    rejected, // error state, can be used to indicate that a request failed, server rejected the request, or timeout was reached
};

pub const PendingRequest = struct {
    idx: u32, // index in pending requests map
    value: ?*anyopaque = null,
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.free),

    client: *Client, // used to access shared mutex and condition variable for awaiting threads and deserializer

    // called by worker, deserializes reader into value, sets state to fulfilled, and wakes awaiting threads
    resolve: *const fn (self: *PendingRequest, reader: *std.io.Reader) anyerror!void = undefined, // needs type info to deserialize

    // called by pending_requests_map during clear or deinit, destroys the value if it is fulfilled and sets state to free
    destroy: *const fn (self: *PendingRequest) anyerror!void = undefined, // needs type info to destroy recursively using deserializer

    pub fn await(self: *PendingRequest) !*anyopaque {
        if (self.state.load(.acquire) == .fulfilled)
            return self.value.?;

        self.client.promise_mutex.lock();
        defer self.client.promise_mutex.unlock();

        while (self.state.load(.acquire) == .pending) {
            self.client.promise_condition.wait(&self.client.promise_mutex);
        }

        if (self.state.load(.acquire) != .fulfilled) {
            return error.PromiseNotFulfilled;
        }

        return self.value.?;
    }

    pub fn release(self: *PendingRequest) void {
        self.state.store(.free, .release);
        self.client.pending_requests_map.release(self.idx) catch {
            std.debug.print("failed to release request\n", .{});
        };
    }
};
