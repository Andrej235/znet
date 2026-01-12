const std = @import("std");
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;

pub const PendingRequest = struct {
    promise: *anyopaque,
    resolve: *const fn (deserializer: *Deserializer, reader: *std.io.Reader, request_promise: *anyopaque) anyerror!void,
};
