const std = @import("std");
const SerializationErrors = @import("../errors.zig").SerializationErrors;

pub const Serializer = struct {
    pub fn serialize(comptime T: type, writer: *std.Io.Writer, data: T) SerializationErrors!void {
        const info = @typeInfo(T);

        switch (info) {
            .@"struct" => |struct_info| try serializeStruct(writer, data, struct_info),
            .@"union" => |union_info| try serializeUnion(writer, data, union_info),
            .array => |array_info| try serializeArray(writer, data, array_info),
            .pointer => |pointer_info| try serializePointer(writer, data, pointer_info),
            .optional => |optional_info| try serializeOptional(writer, data, optional_info),
            .error_union => |error_union_info| try serializeErrorUnion(writer, data, error_union_info),
            .bool => try serializeBool(writer, data),
            .int => |int_info| try serializeInt(writer, data, int_info),
            .float => |float_info| try serializeFloat(writer, data, float_info),
            .@"enum" => |enum_info| try serializeEnum(writer, data, enum_info),
            .comptime_int => @compileError("Comptime integers cannot be serialized directly, consider converting to a regular integer type before serialization"),
            .comptime_float => @compileError("Comptime floats cannot be serialized directly, consider converting to a regular float type before serialization"),
            .error_set => @compileError("Direct serialization of error sets is not supported, consider using an error union instead"),
            .vector => @compileError("Vectors are not a data format, they are a computation type tied to target ABI / SIMD width and thus cannot be serialized directly. Consider converting to an array or slice before serialization"),
            .frame => @compileError("Frames cannot be serialized"),
            .@"anyframe" => @compileError("AnyFrames cannot be serialized"),
            .void => @compileError("Void type cannot be serialized, if you want to serialize nothing, consider using null or an empty struct"),
            .null => @compileError("Null type cannot be serialized, consider using an optional type instead"),
            .undefined => @compileError("Undefined represents an uninitialized value and cannot be serialized"),
            .noreturn => @compileError("Noreturn type cannot be serialized"),
            .type => @compileError("Types only exist at compile time and cannot be serialized"),
            .@"fn" => @compileError("Functions cannot be serialized"),
            .@"opaque" => @compileError("Opaque types cannot be serialized due to lack of type information at compile time"),
            .enum_literal => @compileError("Enum literals cannot be serialized directly, try using the enum type instead"),
        }
    }

    inline fn serializeStruct(writer: *std.Io.Writer, data: anytype, comptime struct_info: std.builtin.Type.Struct) SerializationErrors!void {
        inline for (struct_info.fields) |field| {
            const field_value = @field(data, field.name);
            try serialize(field.type, writer, field_value);
        }
    }

    inline fn serializeUnion(writer: *std.Io.Writer, data: anytype, comptime union_info: std.builtin.Type.Union) SerializationErrors!void {
        if (union_info.tag_type) |enum_tag_type| {
            try serializeEnum(writer, data, @typeInfo(enum_tag_type).@"enum");

            const active = @intFromEnum(data);
            inline for (union_info.fields, 0..) |field, index| {
                const current = @typeInfo(enum_tag_type).@"enum".fields[index].value;

                if (active == current) {
                    const field_value = @field(data, field.name);
                    try serialize(field.type, writer, field_value);
                    return;
                }
            }

            return error.InvalidUnionTag;
        } else {
            @compileError("Untagged unions are not supported");
        }
    }

    inline fn serializeArray(writer: *std.Io.Writer, data: anytype, comptime array_info: std.builtin.Type.Array) SerializationErrors!void {
        const len = array_info.len;
        if (comptime array_info.child == u8) {
            writer.writeAll(&data) catch return error.IntegerSerializationFailed;
            return;
        }

        for (0..len) |i| {
            const element = data[i];
            try serialize(array_info.child, writer, element);
        }
    }

    inline fn serializePointer(writer: *std.Io.Writer, data: anytype, comptime pointer_info: std.builtin.Type.Pointer) SerializationErrors!void {
        switch (pointer_info.size) {
            .one => {
                const pointed_value = data.*;
                try serialize(pointer_info.child, writer, pointed_value);
            },
            .many => {
                @compileError("Many pointers are not supported, consider using a slice instead");
            },
            .c => {
                @compileError("C pointers are not supported, consider using a slice instead");
            },
            .slice => {
                const len = data.len;
                writer.writeInt(@TypeOf(len), len, .big) catch return error.IntegerSerializationFailed;

                if (comptime pointer_info.child == u8) {
                    writer.writeAll(data) catch return error.IntegerSerializationFailed;
                    return;
                }

                for (0..len) |i| {
                    const element = data[i];
                    try serialize(pointer_info.child, writer, element);
                }
            },
        }
    }

    inline fn serializeOptional(writer: *std.Io.Writer, data: anytype, comptime optional_info: std.builtin.Type.Optional) SerializationErrors!void {
        const is_some = data != null;
        try serializeBool(writer, is_some);
        if (is_some) {
            try serialize(optional_info.child, writer, data.?);
        }
    }

    inline fn serializeErrorUnion(writer: *std.Io.Writer, data: anytype, comptime error_union_info: std.builtin.Type.ErrorUnion) SerializationErrors!void {
        const set_info = @typeInfo(error_union_info.error_set).error_set;

        const safe_data = data catch |err| {
            if (set_info) |errors| {
                const err_value = try errorToInt(error_union_info.error_set, errors, err);

                try serializeBool(writer, true);
                try serializeInt(writer, err_value, @typeInfo(u16).int);
                return;
            }

            @compileError("Inferred error sets are not supported");
        };

        try serializeBool(writer, false);
        try serialize(error_union_info.payload, writer, safe_data);
    }

    inline fn errorToInt(comptime TErrorsType: type, comptime errors: []const std.builtin.Type.Error, err: anyerror) SerializationErrors!u16 {
        const names = comptime blk: {
            var tmp: [errors.len][]const u8 = undefined;
            for (errors, 0..) |e, i|
                tmp[i] = e.name;

            std.mem.sort([]const u8, &tmp, {}, struct {
                pub fn cmp(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.cmp);

            break :blk tmp;
        };

        inline for (names, 0..) |curr, idx| {
            const instance = @field(TErrorsType, curr);
            if (err == instance) {
                return idx;
            }
        }

        return SerializationErrors.InvalidErrorUnionValue;
    }

    inline fn serializeBool(writer: *std.Io.Writer, data: bool) SerializationErrors!void {
        const byte_value: u8 = if (data) 1 else 0;
        writer.writeInt(u8, byte_value, .big) catch return error.IntegerSerializationFailed;
    }

    inline fn serializeInt(writer: *std.Io.Writer, data: anytype, comptime int_info: std.builtin.Type.Int) SerializationErrors!void {
        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;

        // early return to avoid unnecessary casts
        if (int_info.bits == bit_size_with_padding) {
            writer.writeInt(@TypeOf(data), data, .big) catch return error.IntegerSerializationFailed;
            return;
        }

        const PaddedType = @Type(.{
            .int = .{
                .signedness = int_info.signedness,
                .bits = bit_size_with_padding,
            },
        });
        const padded_data: PaddedType = @intCast(data);
        writer.writeInt(PaddedType, padded_data, .big) catch return error.IntegerSerializationFailed;
    }

    inline fn serializeFloat(writer: *std.Io.Writer, data: anytype, comptime float_info: std.builtin.Type.Float) SerializationErrors!void {
        const TURepresentation = @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = float_info.bits,
            },
        });

        const uint_representation: TURepresentation = @bitCast(data);
        writer.writeInt(TURepresentation, uint_representation, .big) catch return error.IntegerSerializationFailed;
    }

    inline fn serializeEnum(writer: *std.Io.Writer, data: anytype, comptime enum_info: std.builtin.Type.Enum) SerializationErrors!void {
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

    pub fn count(comptime T: type, data: T) SerializationErrors!u32 {
        const info = @typeInfo(T);

        return (comptime tryCountInComptime(T)) orelse switch (info) {
            .@"struct" => |struct_info| try countStruct(data, struct_info),
            .@"union" => |union_info| try countUnion(data, union_info),
            .array => |array_info| try countArray(data, array_info),
            .pointer => |pointer_info| try countPointer(data, pointer_info),
            .optional => |optional_info| try countOptional(data, optional_info),
            .error_union => |error_union_info| try countErrorUnion(data, error_union_info),
            .bool => 1,
            .int => |int_info| countInt(int_info),
            .float => |float_info| float_info.bits / 8,
            .@"enum" => |enum_info| countEnum(enum_info),
            .comptime_int => @compileError("Comptime integers cannot be countd directly, consider converting to a regular integer type before serialization"),
            .comptime_float => @compileError("Comptime floats cannot be countd directly, consider converting to a regular float type before serialization"),
            .error_set => @compileError("Direct serialization of error sets is not supported, consider using an error union instead"),
            .vector => @compileError("Vectors are not a data format, they are a computation type tied to target ABI / SIMD width and thus cannot be countd directly. Consider converting to an array or slice before serialization"),
            .frame => @compileError("Frames cannot be countd"),
            .@"anyframe" => @compileError("AnyFrames cannot be countd"),
            .void => @compileError("Void type cannot be countd, if you want to count nothing, consider using null or an empty struct"),
            .null => @compileError("Null type cannot be countd, consider using an optional type instead"),
            .undefined => @compileError("Undefined represents an uninitialized value and cannot be countd"),
            .noreturn => @compileError("Noreturn type cannot be countd"),
            .type => @compileError("Types only exist at compile time and cannot be countd"),
            .@"fn" => @compileError("Functions cannot be countd"),
            .@"opaque" => @compileError("Opaque types cannot be countd due to lack of type information at compile time"),
            .enum_literal => @compileError("Enum literals cannot be countd directly, try using the enum type instead"),
        };
    }

    inline fn countStruct(data: anytype, comptime struct_info: std.builtin.Type.Struct) SerializationErrors!u32 {
        var total_bytes: u32 = 0;
        inline for (struct_info.fields) |field| {
            const field_value = @field(data, field.name);
            total_bytes += try count(field.type, field_value);
        }
        return total_bytes;
    }

    inline fn countUnion(data: anytype, comptime union_info: std.builtin.Type.Union) SerializationErrors!u32 {
        if (union_info.tag_type) |enum_tag_type| {
            const active = @intFromEnum(data);
            inline for (union_info.fields, 0..) |field, index| {
                const current = @typeInfo(enum_tag_type).@"enum".fields[index].value;

                if (active == current) {
                    const field_value = @field(data, field.name);
                    return try count(field.type, field_value) + countEnum(@typeInfo(enum_tag_type).@"enum");
                }
            }

            return error.InvalidUnionTag;
        } else {
            @compileError("Untagged unions are not supported");
        }
    }

    inline fn countArray(data: anytype, comptime array_info: std.builtin.Type.Array) SerializationErrors!u32 {
        const len = array_info.len;
        var size: u32 = 0;
        comptime if (tryCountInComptime(array_info.child)) |child_size| {
            return len * child_size;
        };

        for (0..len) |i| {
            size += try count(array_info.child, data[i]);
        }
        return size;
    }

    inline fn countPointer(data: anytype, comptime pointer_info: std.builtin.Type.Pointer) SerializationErrors!u32 {
        return blk: switch (pointer_info.size) {
            .one => {
                comptime if (tryCountInComptime(@TypeOf(data))) |child_size| {
                    break :blk child_size;
                };

                break :blk try count(pointer_info.child, data.*);
            },
            .many => {
                @compileError("Many pointers are not supported, consider using a slice instead");
            },
            .c => {
                @compileError("C pointers are not supported, consider using a slice instead");
            },
            .slice => {
                const len = data.len;
                var size: u32 = @sizeOf(@TypeOf(len));

                if (comptime tryCountInComptime(pointer_info.child)) |child_size| {
                    break :blk child_size * @as(u32, @intCast(len)) + size;
                }

                for (0..len) |i| {
                    size += try count(pointer_info.child, data[i]);
                }
                break :blk size;
            },
        };
    }

    inline fn tryCountInComptime(comptime T: type) ?u32 {
        comptime {
            const info = @typeInfo(T);
            return switch (info) {
                .@"struct" => |struct_info| blk: {
                    var total_bytes: u32 = 0;
                    for (struct_info.fields) |field| {
                        total_bytes += tryCountInComptime(field.type) orelse break :blk null;
                    }
                    break :blk total_bytes;
                },

                .array => |array_info| blk: {
                    const child = tryCountInComptime(array_info.child) orelse break :blk null;
                    break :blk child * @as(u32, array_info.len);
                },

                .pointer => |pointer_info| switch (pointer_info.size) {
                    .one => tryCountInComptime(pointer_info.child),
                    else => null,
                },

                .bool => 1,
                .float => |float_info| float_info.bits / 8,
                .int => |int_info| countInt(int_info),
                .@"enum" => |enum_info| countEnum(enum_info),
                else => null,
            };
        }
    }

    inline fn countOptional(data: anytype, comptime optional_info: std.builtin.Type.Optional) SerializationErrors!u32 {
        return if (data) |d| 1 + try count(optional_info.child, d) else 1;
    }

    inline fn countErrorUnion(data: anytype, comptime error_union_info: std.builtin.Type.ErrorUnion) SerializationErrors!u32 {
        const safe_data = data catch return 3; // 1 byte for bool + 2 bytes for u16 error code
        return try count(error_union_info.payload, safe_data) + 1;
    }

    inline fn countEnum(comptime enum_info: std.builtin.Type.Enum) u32 {
        const int_info = @typeInfo(enum_info.tag_type).int;
        if (int_info.signedness == .signed) {
            @compileError("Signed enum tag types are not supported");
        }

        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;
        return bit_size_with_padding / 8;
    }

    inline fn countInt(comptime int_info: std.builtin.Type.Int) u32 {
        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;
        return bit_size_with_padding / 8;
    }
};
