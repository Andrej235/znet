const std = @import("std");
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const DeserializationErrors = @import("../serializer/errors.zig").DeserializationErrors;
const Client = @import("client.zig").Client;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const State = enum(u8) {
    free,
    pending,
    fulfilled,
    rejected, // error state, can be used to indicate that a request failed, server rejected the request, or timeout was reached
};

pub const PendingRequest = struct {
    idx: u32, // index in pending requests map
    data: []const u8 = undefined,
    inbound_buffer_idx: u32 = undefined,

    state: State = .free,

    client: *Client, // used to access shared mutex and condition variable for awaiting threads and deserializer

    pub fn resolve(self: *PendingRequest, data: []const u8, inbound_buffer_idx: u32) void {
        self.data = data;
        self.inbound_buffer_idx = inbound_buffer_idx;
        self.state = .fulfilled;
        self.client.promise_condition.broadcast();
    }

    pub fn AwaitResult(comptime T: type) type {
        const info = @typeInfo(T);
        if (info != .error_union) return FetchErrors!T;

        const error_info = info.error_union;
        return (error_info.error_set || FetchErrors)!error_info.payload;
    }

    pub const FetchErrors = error{
        DeserializationFailed,
        FetchFailed,
    };

    pub inline fn await(self: *PendingRequest, comptime T: type) AwaitResult(T) {
        const info = @typeInfo(T);

        if (self.state == .fulfilled) {
            var reader = std.io.Reader.fixed(self.data);
            _ = deserializeMessageHeaders(&reader) catch return FetchErrors.DeserializationFailed;

            if (comptime info != .error_set) {
                return self.client.deserializer.deserialize(&reader, T) catch return FetchErrors.DeserializationFailed;
            } else {
                return self.client.deserializer.deserialize(&reader, T) catch |err| switch (err) {
                    DeserializationErrors.AllocationFailed,
                    DeserializationErrors.BooleanDeserializationFailed,
                    DeserializationErrors.EndOfStream,
                    DeserializationErrors.IntegerDeserializationFailed,
                    DeserializationErrors.InvalidBooleanValue,
                    DeserializationErrors.InvalidUnionTag,
                    DeserializationErrors.OutOfMemory,
                    DeserializationErrors.UnexpectedEof,
                    => return err,
                    else => @errorCast(err),
                };
            }
        }

        self.client.promise_mutex.lock();
        defer self.client.promise_mutex.unlock();

        while (self.state == .pending) {
            self.client.promise_condition.wait(&self.client.promise_mutex);
        }

        if (self.state == .rejected) {
            return FetchErrors.FetchFailed;
        }

        var reader = std.io.Reader.fixed(self.data);
        _ = deserializeMessageHeaders(&reader) catch return FetchErrors.DeserializationFailed;
        if (comptime info != .error_set) {
            return self.client.deserializer.deserialize(&reader, T) catch return FetchErrors.DeserializationFailed;
        } else {
            return self.client.deserializer.deserialize(&reader, T) catch |err| switch (err) {
                DeserializationErrors.AllocationFailed,
                DeserializationErrors.BooleanDeserializationFailed,
                DeserializationErrors.EndOfStream,
                DeserializationErrors.IntegerDeserializationFailed,
                DeserializationErrors.InvalidBooleanValue,
                DeserializationErrors.InvalidUnionTag,
                DeserializationErrors.OutOfMemory,
                DeserializationErrors.UnexpectedEof,
                => return err,
                else => @errorCast(err),
            };
        }
    }

    pub fn release(self: *PendingRequest) void {
        self.state = .free;

        self.client.inbound_buffer_pool.release(self.inbound_buffer_idx);
        self.client.pending_requests_map.release(self.idx) catch {
            std.debug.print("failed to release request\n", .{});
        };
    }
};
