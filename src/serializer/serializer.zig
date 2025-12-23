const std = @import("std");

pub const Serializer = struct {
    pub fn serialize(writer: anytype, comptime data: anytype) !void {
        const T = @TypeOf(data);

        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => |struct_info| try serializeStruct(writer, data, struct_info),
            .array => |array_info| try serializeArray(writer, data, array_info),
            .pointer => |pointer_info| try serializePointer(writer, data, pointer_info),
            .int => |int_info| try serializeInt(writer, data, int_info),
            .comptime_int => try serializeComptimeInt(writer, data),
            .float => |float_info| try serializeFloat(writer, data, float_info),
            .comptime_float => try serializeComptimeFloat(writer, data),
            else => {
                try writer.writeAll("Unhandled data " ++ @typeName(T) ++ "\n");
            },
        }
    }

    inline fn serializeStruct(writer: anytype, comptime data: anytype, comptime struct_info: std.builtin.Type.Struct) !void {
        inline for (struct_info.fields) |field| {
            const field_value = @field(data, field.name);
            try serialize(writer, field_value);
        }
    }

    inline fn serializeArray(writer: anytype, comptime data: anytype, comptime array_info: std.builtin.Type.Array) !void {
        const len = array_info.len;
        inline for (0..len) |i| {
            const element = data[i];
            try serialize(writer, element);
        }
    }

    inline fn serializePointer(writer: anytype, comptime data: anytype, comptime pointer_info: std.builtin.Type.Pointer) !void {
        const TChild = pointer_info.child;

        // string
        if (TChild == u8) {
            const len = data.len;
            try writer.writeInt(@TypeOf(len), len, .big);
            try writer.writeAll(data);
            return;
        }
    }

    inline fn serializeInt(writer: anytype, comptime data: anytype, comptime _: std.builtin.Type.Int) !void {
        try writer.writeInt(@TypeOf(data), data, .big);
    }

    inline fn serializeComptimeInt(writer: anytype, comptime data: anytype) !void {
        try serializeInt(writer, @as(i32, @intCast(data)), @typeInfo(i32).int);
    }

    inline fn serializeFloat(writer: anytype, comptime data: anytype, comptime float_info: std.builtin.Type.Float) !void {
        const TURepresentation = @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = float_info.bits,
            },
        });

        const uint_representation: TURepresentation = @bitCast(data);
        try writer.writeInt(TURepresentation, uint_representation, .big);
    }

    inline fn serializeComptimeFloat(writer: anytype, comptime data: anytype) !void {
        try serializeFloat(writer, @as(f32, @floatCast(data)), @typeInfo(f32).float);
    }
};
