const std = @import("std");
const DeserializationErrors = @import("errors.zig").DeserializationErrors;

pub const Deserializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Deserializer {
        return Deserializer{
            .allocator = allocator,
        };
    }

    fn DeserializationResult(comptime TExpected: type) type {
        const info = @typeInfo(TExpected);
        return switch (info) {
            .error_set => |err_set_info| t_result: {
                break :t_result if (err_set_info) |_| (TExpected || DeserializationErrors)!void else DeserializationErrors!void;
            },
            .error_union => |err_union_info| t_result: {
                break :t_result (err_union_info.error_set || DeserializationErrors)!err_union_info.payload;
            },
            else => DeserializationErrors!TExpected,
        };
    }

    pub fn deserialize(self: *Deserializer, reader: anytype, comptime T: type) DeserializationResult(T) {
        const info = @typeInfo(T);

        return switch (info) {
            .@"struct" => try self.deserializeStruct(reader, T),
            .@"union" => try self.deserializeUnion(reader, T),
            .array => try self.deserializeArray(reader, T),
            .pointer => try self.deserializePointer(reader, T),
            .optional => try self.deserializeOptional(reader, T),
            .error_union => try self.deserializeErrorUnion(reader, T),
            .bool => try self.deserializeBool(reader),
            .int => try self.deserializeInt(reader, T),
            .float => try self.deserializeFloat(reader, T),
            .comptime_int => @compileError("Comptime integers cannot be serialized directly, consider converting to a regular integer type before serialization"),
            .comptime_float => @compileError("Comptime floats cannot be serialized directly, consider converting to a regular float type before serialization"),
            .@"enum" => try self.deserializeEnum(reader, T),
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

    inline fn deserializeStruct(self: *Deserializer, reader: anytype, comptime TStruct: type) DeserializationErrors!TStruct {
        const info = @typeInfo(TStruct).@"struct";
        var instance: TStruct = undefined;

        inline for (info.fields) |field| {
            const field_value = try self.deserialize(reader, field.type);
            @field(instance, field.name) = field_value;
        }
        return instance;
    }

    inline fn deserializeUnion(self: *Deserializer, reader: anytype, comptime TUnion: type) DeserializationErrors!TUnion {
        const union_info = @typeInfo(TUnion).@"union";
        if (union_info.tag_type) |enum_tag_type| {
            const active = @intFromEnum(try self.deserializeEnum(reader, enum_tag_type));

            inline for (union_info.fields, 0..) |field, index| {
                const current = @typeInfo(enum_tag_type).@"enum".fields[index].value;

                if (active == current) {
                    const field_value = try self.deserialize(reader, field.type);
                    return @unionInit(TUnion, field.name, field_value);
                }
            }

            return error.InvalidUnionTag;
        } else {
            @compileError("Unions without tag types are not supported");
        }
    }

    inline fn deserializeArray(self: *Deserializer, reader: anytype, comptime TArray: type) DeserializationErrors!TArray {
        const array_info = @typeInfo(TArray).array;
        const len = array_info.len;
        var instance: TArray = undefined;

        inline for (0..len) |i| {
            const element = try self.deserialize(reader, array_info.child);
            instance[i] = element;
        }
        return instance;
    }

    inline fn deserializePointer(self: *Deserializer, reader: anytype, comptime TPointer: type) DeserializationErrors!TPointer {
        const pointer_info = @typeInfo(TPointer).pointer;
        const TChild = pointer_info.child;

        switch (pointer_info.size) {
            .one => {
                const pointed_value = try self.allocator.create(TChild);
                pointed_value.* = try self.deserialize(reader, TChild);
                return pointed_value;
            },
            .many => {
                if (pointer_info.sentinel()) |sentinel| {
                    const len = try self.deserializeInt(reader, usize);
                    const buf = try self.allocator.allocSentinel(
                        TChild,
                        len,
                        sentinel,
                    );

                    try reader.readNoEof(buf[0..len]);
                    return buf;
                } else {
                    // It is impossible to iterate over a many pointer without a sentinel
                    @compileError("Many pointers must have a sentinel to be serializable");
                }
            },
            .c => {
                @compileError("C pointers are not supported, try converting to a slice or many-pointer instead");
            },
            .slice => {
                const len = try self.deserializeInt(reader, usize);
                const buf = if (pointer_info.sentinel()) |sentinel| try self.allocator.allocSentinel(
                    TChild,
                    len,
                    sentinel,
                ) else try self.allocator.alloc(TChild, len);

                for (0..len) |i| {
                    buf[i] = try self.deserialize(reader, TChild);
                }

                return buf;
            },
        }
    }

    inline fn deserializeOptional(self: *Deserializer, reader: anytype, comptime TOptional: type) DeserializationErrors!TOptional {
        const optional_info = @typeInfo(TOptional).optional;
        const is_some = try self.deserializeBool(reader);
        if (is_some) {
            const value = try self.deserialize(reader, optional_info.child);
            return value;
        } else {
            return null;
        }
    }

    inline fn deserializeErrorUnion(self: *Deserializer, reader: anytype, comptime T: type) DeserializationResult(T) {
        const info = @typeInfo(T).error_union;

        const is_error = try self.deserializeBool(reader);
        if (is_error) {
            const TInt = u16;
            const int_value = try self.deserializeInt(reader, TInt);
            const err = @errorFromInt(int_value);
            return @errorCast(err);
        } else {
            const payload = try self.deserialize(reader, info.payload);
            return payload;
        }
    }

    inline fn deserializeBool(_: *Deserializer, reader: anytype) !bool {
        const byte = try reader.readByte();
        return switch (byte) {
            0 => false,
            1 => true,
            else => error.InvalidBooleanValue,
        };
    }

    inline fn deserializeInt(_: *Deserializer, reader: anytype, comptime TInt: type) DeserializationErrors!TInt {
        return try reader.readInt(TInt, .big);
    }

    inline fn deserializeComptimeInt(_: *Deserializer, reader: anytype) DeserializationErrors!comptime_int {
        return try reader.readInt(i32, .big);
    }

    inline fn deserializeFloat(_: *Deserializer, reader: anytype, comptime T: type) DeserializationErrors!T {
        const TURepresentation = @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = @sizeOf(T) * 8,
            },
        });

        const int_value: TURepresentation = try reader.readInt(TURepresentation, .big);
        return @bitCast(int_value);
    }

    inline fn deserializeComptimeFloat(self: *Deserializer, reader: anytype) DeserializationErrors!comptime_float {
        return self.deserializeFloat(reader, f32);
    }

    inline fn deserializeEnum(self: *Deserializer, reader: anytype, comptime T: type) DeserializationErrors!T {
        const enum_info = @typeInfo(T).@"enum";
        const int_info = @typeInfo(enum_info.tag_type).int;
        if (int_info.signedness == .signed) {
            @compileError("Signed enum tag types are not supported");
        }

        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;
        const int_info_padded = std.builtin.Type.Int{
            .bits = bit_size_with_padding,
            .signedness = int_info.signedness,
        };

        return @enumFromInt(try self.deserializeInt(reader, @Type(.{ .int = int_info_padded })));
    }
};
