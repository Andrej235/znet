const std = @import("std");

pub const Serializer = struct {
    pub fn serialize(comptime T: type, writer: anytype, data: T) !void {
        const info = @typeInfo(T);

        switch (info) {
            .@"struct" => |struct_info| try serializeStruct(writer, data, struct_info),
            .array => |array_info| try serializeArray(writer, data, array_info),
            .pointer => |pointer_info| try serializePointer(writer, data, pointer_info),
            .optional => |optional_info| try serializeOptional(writer, data, optional_info),
            .bool => try serializeBool(writer, data),
            .int => |int_info| try serializeInt(writer, data, int_info),
            .comptime_int => try serializeComptimeInt(writer, data),
            .float => |float_info| try serializeFloat(writer, data, float_info),
            .comptime_float => try serializeComptimeFloat(writer, data),
            .@"enum" => |enum_info| try serializeEnum(writer, data, enum_info),
            .@"fn" => @compileError("Functions cannot be serialized"),
            .@"opaque" => @compileError("Opaque types cannot be serialized due to lack of type information at compile time"),
            .enum_literal => @compileError("Enum literals cannot be serialized directly, try using the enum type instead"),
            else => @compileError("Unhandled data " ++ @typeName(T) ++ "\n"),
        }
    }

    inline fn serializeStruct(writer: anytype, data: anytype, comptime struct_info: std.builtin.Type.Struct) !void {
        inline for (struct_info.fields) |field| {
            const field_value = @field(data, field.name);
            try serialize(field.type, writer, field_value);
        }
    }

    inline fn serializeArray(writer: anytype, data: anytype, comptime array_info: std.builtin.Type.Array) !void {
        const len = array_info.len;
        inline for (0..len) |i| {
            const element = data[i];
            try serialize(array_info.child, writer, element);
        }
    }

    inline fn serializePointer(writer: anytype, data: anytype, comptime pointer_info: std.builtin.Type.Pointer) !void {
        switch (pointer_info.size) {
            .one => {
                const pointed_value = data.*;
                try serialize(pointer_info.child, writer, pointed_value);
            },
            .many => {
                if (pointer_info.sentinel()) |sentinel| {
                    const start_pos = try writer.context.getPos();
                    try writer.context.seekBy(@sizeOf(usize));

                    var count: usize = 0;
                    while (data[count] != sentinel) : (count += 1) {
                        try serialize(writer, data[count]);
                    }
                    const end_pos = try writer.context.getPos();

                    writer.context.seekTo(start_pos);
                    try writer.writeInt(usize, count, .big);
                    writer.context.seekTo(end_pos);
                } else {
                    // It is impossible to iterate over a many pointer without a sentinel
                    @compileError("Many pointers must have a sentinel to be serializable");
                }
            },
            .c => {
                @compileError("C pointers are not supported");
            },
            .slice => {
                // todo: optimize for strings, use writeAll
                const len = data.len;
                try writer.writeInt(@TypeOf(len), len, .big);
                for (0..len) |i| {
                    const element = data[i];
                    try serialize(pointer_info.child, writer, element);
                }
            },
        }
    }

    inline fn serializeOptional(writer: anytype, data: anytype, comptime optional_info: std.builtin.Type.Optional) !void {
        const is_some = data != null;
        try serializeBool(writer, is_some);
        if (is_some) {
            try serialize(optional_info.child, writer, data.?);
        }
    }

    inline fn serializeBool(writer: anytype, data: bool) !void {
        const byte_value: u8 = if (data) 1 else 0;
        try writer.writeInt(u8, byte_value, .big);
    }

    inline fn serializeInt(writer: anytype, data: anytype, comptime _: std.builtin.Type.Int) !void {
        try writer.writeInt(@TypeOf(data), data, .big);
    }

    inline fn serializeComptimeInt(writer: anytype, data: anytype) !void {
        try serializeInt(writer, @as(i32, @intCast(data)), @typeInfo(i32).int);
    }

    inline fn serializeFloat(writer: anytype, data: anytype, comptime float_info: std.builtin.Type.Float) !void {
        const TURepresentation = @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = float_info.bits,
            },
        });

        const uint_representation: TURepresentation = @bitCast(data);
        try writer.writeInt(TURepresentation, uint_representation, .big);
    }

    inline fn serializeComptimeFloat(writer: anytype, data: anytype) !void {
        try serializeFloat(writer, @as(f32, @floatCast(data)), @typeInfo(f32).float);
    }

    inline fn serializeEnum(writer: anytype, data: anytype, comptime enum_info: std.builtin.Type.Enum) !void {
        const int_info = @typeInfo(enum_info.tag_type).int;
        if (int_info.signedness == .signed) {
            @compileError("Signed enum tag types are not supported");
        }

        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;
        const int_info_padded = std.builtin.Type.Int{
            .bits = bit_size_with_padding,
            .signedness = int_info.signedness,
        };

        try serializeInt(writer, @as(@Type(.{ .int = int_info_padded }), @intCast(@intFromEnum(data))), int_info_padded);
    }
};
