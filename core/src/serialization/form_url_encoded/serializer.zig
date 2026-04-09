const std = @import("std");
const SerializationErrors = @import("../errors.zig").SerializationErrors;

pub const Serializer = struct {
    pub fn serialize(comptime T: type, writer: *std.Io.Writer, data: T) SerializationErrors!void {
        _ = writer;
        _ = data;

        @panic("Not implemented");
    }
};
