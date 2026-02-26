const std = @import("std");
const Deserializer = @import("../serialization/binary/deserializer.zig").Deserializer;
const DeserializationErrors = @import("../serialization/errors.zig").DeserializationErrors;
const Client = @import("client.zig").ClientInterface;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const Logger = @import("../logger/logger.zig").Logger.scoped(.pending_request);

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

    state: std.atomic.Value(State) = std.atomic.Value(State).init(.free),

    client: *Client, // used to access shared mutex and condition variable for awaiting threads and deserializer

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    pub fn resolve(self: *PendingRequest, data: []const u8, inbound_buffer_idx: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.data = data;
        self.inbound_buffer_idx = inbound_buffer_idx;
        self.state.store(.fulfilled, .release);
        self.condition.broadcast();
    }

    pub fn reject(self: *PendingRequest) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state.store(.rejected, .release);
        self.condition.broadcast();
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
        const current_state = self.state.load(.acquire);

        if (current_state == .fulfilled) {
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
                    => err,
                    else => @errorCast(err),
                };
            }
        }

        if (current_state == .rejected) {
            return FetchErrors.FetchFailed;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.state.load(.acquire) == .pending) {
            self.condition.timedWait(&self.mutex, std.time.ns_per_s) catch {
                Logger.debug("timeout {}, {}", .{ self.idx, self.state.load(.acquire) });
                continue;
            };
        }

        if (self.state.load(.acquire) == .rejected) {
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
        self.state.store(.free, .release);

        self.client.inbound_buffer_pool.release(self.inbound_buffer_idx);
        self.client.pending_requests_map.release(self.idx) catch {
            Logger.err("failed to release request", .{});
        };
    }
};
