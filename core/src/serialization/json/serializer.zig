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

    pub fn count(comptime T: type, data: T) SerializationErrors!usize {
        var null_writer = std.io.Writer.Discarding.init(&[_]u8{});
        const writer = &null_writer.writer;

        const fmt = std.json.fmt(data, .{});
        fmt.format(writer) catch |err| {
            switch (err) {
                else => return SerializationErrors.SerializationFailed,
            }
        };
        return null_writer.fullCount();
    }
};
