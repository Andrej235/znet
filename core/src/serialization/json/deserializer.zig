const std = @import("std");

const DeserializationErrors = @import("../errors.zig").DeserializationErrors;

/// Wrapper around std.json.parseFromTokenSourceLeaky to fit the common serialization interface.
pub const Deserializer = struct {
    pub fn deserialize(allocator: std.mem.Allocator, reader: *std.Io.Reader, comptime T: type) DeserializationErrors!T {
        var json_reader = std.json.Reader.init(allocator, reader);

        return std.json.parseFromTokenSourceLeaky(
            T,
            allocator,
            &json_reader,
            .{
                .allocate = .alloc_if_needed,
                .duplicate_field_behavior = .@"error",
                .ignore_unknown_fields = true,
            },
        ) catch |err| {
            switch (err) {
                else => return DeserializationErrors.InvalidFormat,
            }
        };
    }
};
