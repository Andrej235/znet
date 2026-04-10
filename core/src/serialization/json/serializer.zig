const std = @import("std");
const SerializationErrors = @import("../errors.zig").SerializationErrors;

pub const Serializer = struct {
    pub fn serialize(comptime T: type, writer: *std.Io.Writer, data: T) SerializationErrors!void {
        const fmt = std.json.fmt(data, .{});
        fmt.format(writer) catch |err| {
            switch (err) {
                else => return SerializationErrors.SerializationFailed,
            }
        };
    }
};
