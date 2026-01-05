const std = @import("std");
const SerializationErrors = @import("errors.zig").CountingSerializationErrors;

// todo: optimize for arrays and slices of static types like u8, i32, etc

pub const Serializer = struct {
    pub fn serialize(comptime T: type, data: T) SerializationErrors!u32 {
        const info = @typeInfo(T);

        return switch (info) {
            .@"struct" => |struct_info| try serializeStruct(data, struct_info),
            .@"union" => |union_info| try serializeUnion(data, union_info),
            .array => |array_info| try serializeArray(data, array_info),
            .pointer => |pointer_info| try serializePointer(data, pointer_info),
            .optional => |optional_info| try serializeOptional(data, optional_info),
            .error_union => |error_union_info| try serializeErrorUnion(data, error_union_info),
            .bool => 1,
            .int => |int_info| try serializeInt(int_info),
            .float => |float_info| float_info.bits / 8,
            .@"enum" => |enum_info| try serializeEnum(enum_info),
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
        };
    }

    inline fn serializeStruct(data: anytype, comptime struct_info: std.builtin.Type.Struct) SerializationErrors!u32 {
        var total_bytes: u32 = 0;
        inline for (struct_info.fields) |field| {
            const field_value = @field(data, field.name);
            total_bytes += try serialize(field.type, field_value);
        }
        return total_bytes;
    }

    inline fn serializeUnion(data: anytype, comptime union_info: std.builtin.Type.Union) SerializationErrors!u32 {
        if (union_info.tag_type) |enum_tag_type| {
            const active = @intFromEnum(data);
            inline for (union_info.fields, 0..) |field, index| {
                const current = @typeInfo(enum_tag_type).@"enum".fields[index].value;

                if (active == current) {
                    const field_value = @field(data, field.name);
                    return try serialize(field.type, field_value) + try serializeEnum(data, @typeInfo(enum_tag_type).@"enum");
                }
            }

            return error.InvalidUnionTag;
        } else {
            @compileError("Untagged unions are not supported");
        }
    }

    inline fn serializeArray(data: anytype, comptime array_info: std.builtin.Type.Array) SerializationErrors!u32 {
        const len = array_info.len;
        var size: u32 = 0;
        inline for (0..len) |i| {
            size += try serialize(array_info.child, data[i]);
        }
        return size;
    }

    inline fn serializePointer(data: anytype, comptime pointer_info: std.builtin.Type.Pointer) SerializationErrors!u32 {
        return blk: switch (pointer_info.size) {
            .one => {
                break :blk try serialize(pointer_info.child, data.*);
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
                for (0..len) |i| {
                    size += try serialize(pointer_info.child, data[i]);
                }
                break :blk size;
            },
        };
    }

    inline fn serializeOptional(data: anytype, comptime optional_info: std.builtin.Type.Optional) SerializationErrors!u32 {
        return if (data) |d| 1 + try serialize(optional_info.child, d) else 1;
    }

    inline fn serializeErrorUnion(data: anytype, comptime error_union_info: std.builtin.Type.ErrorUnion) SerializationErrors!u32 {
        const safe_data = data catch return 3; // 1 byte for bool + 2 bytes for u16 error code
        return try serialize(error_union_info.payload, safe_data) + 1;
    }

    inline fn serializeEnum(comptime enum_info: std.builtin.Type.Enum) SerializationErrors!u32 {
        const int_info = @typeInfo(enum_info.tag_type).int;
        if (int_info.signedness == .signed) {
            @compileError("Signed enum tag types are not supported");
        }

        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;
        return bit_size_with_padding / 8;
    }

    inline fn serializeInt(comptime int_info: std.builtin.Type.Int) SerializationErrors!u32 {
        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;
        return bit_size_with_padding / 8;
    }
};
