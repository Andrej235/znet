const std = @import("std");

const DeserializationErrors = @import("errors.zig").DeserializationErrors;

pub const Deserializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Deserializer {
        return Deserializer{
            .allocator = allocator,
        };
    }

    pub fn DeserializationResult(comptime TExpected: type) type {
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

    pub fn deserialize(self: *Deserializer, reader: *std.Io.Reader, comptime T: type) DeserializationResult(T) {
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

    inline fn deserializeStruct(self: *Deserializer, reader: *std.Io.Reader, comptime TStruct: type) DeserializationErrors!TStruct {
        const info = @typeInfo(TStruct).@"struct";
        var instance: TStruct = undefined;

        inline for (info.fields) |field| {
            const field_value = try self.deserialize(reader, field.type);
            @field(instance, field.name) = field_value;
        }
        return instance;
    }

    inline fn deserializeUnion(self: *Deserializer, reader: *std.Io.Reader, comptime TUnion: type) DeserializationErrors!TUnion {
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

    inline fn deserializeArray(self: *Deserializer, reader: *std.Io.Reader, comptime TArray: type) DeserializationErrors!TArray {
        const array_info = @typeInfo(TArray).array;
        const TChild = array_info.child;
        const len = array_info.len;
        var instance: TArray = undefined;

        if (comptime TChild == u8) {
            reader.readSliceAll(&instance) catch return DeserializationErrors.SliceDeserializationFailed;
            return instance;
        }

        for (0..len) |i| {
            instance[i] = try self.deserialize(reader, TChild);
        }
        return instance;
    }

    inline fn deserializePointer(self: *Deserializer, reader: *std.Io.Reader, comptime TPointer: type) DeserializationErrors!TPointer {
        const pointer_info = @typeInfo(TPointer).pointer;
        const TChild = pointer_info.child;

        switch (pointer_info.size) {
            .one => {
                const pointed_value = try self.allocator.create(TChild);
                pointed_value.* = try self.deserialize(reader, TChild);
                return pointed_value;
            },
            .many => {
                @compileError("Many pointers are not supported, consider using a slice instead");
            },
            .c => {
                @compileError("C pointers are not supported, consider using a slice instead");
            },
            .slice => {
                const len = try self.deserializeInt(reader, usize);
                const buf = if (pointer_info.sentinel()) |sentinel| try self.allocator.allocSentinel(
                    TChild,
                    len,
                    sentinel,
                ) else try self.allocator.alloc(TChild, len);

                if (comptime TChild == u8) {
                    reader.readSliceAll(buf) catch return DeserializationErrors.SliceDeserializationFailed;
                    return buf;
                }

                for (0..len) |i| {
                    buf[i] = try self.deserialize(reader, TChild);
                }

                return buf;
            },
        }
    }

    inline fn deserializeOptional(self: *Deserializer, reader: *std.Io.Reader, comptime TOptional: type) DeserializationErrors!TOptional {
        const optional_info = @typeInfo(TOptional).optional;
        const is_some = try self.deserializeBool(reader);
        if (is_some) {
            const value = try self.deserialize(reader, optional_info.child);
            return value;
        } else {
            return null;
        }
    }

    inline fn deserializeErrorUnion(self: *Deserializer, reader: *std.Io.Reader, comptime T: type) DeserializationResult(T) {
        const info = @typeInfo(T).error_union;

        const is_error = try self.deserializeBool(reader);
        if (is_error) {
            const int_value = try self.deserializeInt(reader, u16);
            return intToError(info.error_set, int_value, T);
        } else {
            const payload = try self.deserialize(reader, info.payload);
            return payload;
        }
    }

    inline fn intToError(comptime TErrorsType: type, error_value: u16, comptime T: type) DeserializationResult(T) {
        const error_set_info = @typeInfo(TErrorsType).error_set;
        if (error_set_info == null) {
            @compileError("Inferred error sets are not supported");
        }
        const errors = error_set_info.?;

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

        if (error_value >= names.len) {
            return DeserializationErrors.InvalidErrorUnionValue;
        }

        inline for (names, 0..) |curr, idx| {
            const instance = @field(TErrorsType, curr);
            if (idx == error_value) {
                return instance;
            }
        }

        return DeserializationErrors.InvalidErrorUnionValue;
    }

    inline fn deserializeBool(_: *Deserializer, reader: *std.Io.Reader) DeserializationErrors!bool {
        const byte = reader.takeByte() catch return DeserializationErrors.BooleanDeserializationFailed;
        return switch (byte) {
            0 => false,
            1 => true,
            else => error.InvalidBooleanValue,
        };
    }

    inline fn deserializeInt(_: *Deserializer, reader: *std.Io.Reader, comptime TInt: type) DeserializationErrors!TInt {
        const int_info = @typeInfo(TInt).int;
        const bit_size_with_padding = comptime (int_info.bits + 7) / 8 * 8;

        // early return to avoid unnecessary casts
        if (int_info.bits == bit_size_with_padding) {
            return reader.takeInt(TInt, .big) catch return error.IntegerDeserializationFailed;
        }

        const PaddedType = @Type(.{
            .int = .{
                .signedness = int_info.signedness,
                .bits = bit_size_with_padding,
            },
        });
        const padded_value: PaddedType = reader.takeInt(PaddedType, .big) catch return error.IntegerDeserializationFailed;
        return @intCast(padded_value);
    }

    inline fn deserializeFloat(_: *Deserializer, reader: *std.Io.Reader, comptime T: type) DeserializationErrors!T {
        const TURepresentation = @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = @sizeOf(T) * 8,
            },
        });

        const int_value: TURepresentation = reader.takeInt(TURepresentation, .big) catch return DeserializationErrors.IntegerDeserializationFailed;
        return @bitCast(int_value);
    }

    inline fn deserializeEnum(self: *Deserializer, reader: *std.Io.Reader, comptime T: type) DeserializationErrors!T {
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

    /// Recursively frees all memory associated with the given data structure
    ///
    /// Given data must have been deserialized using this deserializer instance
    /// or allocated using the same allocator
    pub fn destroy(self: *Deserializer, data: anytype) !void {
        const T = @TypeOf(data);
        const info = @typeInfo(T);

        switch (info) {
            .@"struct" => |struct_info| try self.destroyStruct(data, struct_info),
            .@"union" => |union_info| try self.destroyUnion(data, union_info),
            .array => |array_info| try self.destroyArray(data, array_info),
            .pointer => |pointer_info| try self.destroyPointer(data, pointer_info),
            .optional => try self.destroyOptional(data),
            .error_union => try self.destroyErrorUnion(data),
            .bool => return,
            .int => return,
            .float => return,
            .@"enum" => return,
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

    inline fn destroyStruct(self: *Deserializer, data: anytype, comptime struct_info: std.builtin.Type.Struct) DeserializationErrors!void {
        inline for (struct_info.fields) |field| {
            const field_value = @field(data, field.name);
            try self.destroy(field_value);
        }
    }

    inline fn destroyUnion(self: *Deserializer, data: anytype, comptime union_info: std.builtin.Type.Union) DeserializationErrors!void {
        if (union_info.tag_type) |enum_tag_type| {
            const active = @intFromEnum(data);
            inline for (union_info.fields, 0..) |field, index| {
                const current = @typeInfo(enum_tag_type).@"enum".fields[index].value;

                if (active == current) {
                    const field_value = @field(data, field.name);
                    try self.destroy(field_value);
                    return;
                }
            }
        } else {
            @compileError("Untagged unions are not supported");
        }
    }

    inline fn destroyArray(self: *Deserializer, data: anytype, comptime array_info: std.builtin.Type.Array) DeserializationErrors!void {
        const len = array_info.len;

        for (0..len) |i| {
            const element = data[i];
            try self.destroy(element);
        }
    }

    inline fn destroyPointer(self: *Deserializer, data: anytype, comptime pointer_info: std.builtin.Type.Pointer) DeserializationErrors!void {
        switch (pointer_info.size) {
            .one => {
                const pointed_value = data.*;
                try self.destroy(pointed_value);
                self.allocator.destroy(data);
            },
            .many => {
                @compileError("Many pointers are not supported, consider using a slice instead");
            },
            .c => {
                @compileError("C pointers are not supported, consider using a slice instead");
            },
            .slice => {
                const slice = data;
                for (slice) |element| {
                    try self.destroy(element);
                }
                self.allocator.free(slice);
            },
        }
    }

    inline fn destroyOptional(self: *Deserializer, data: anytype) DeserializationErrors!void {
        if (data) |value| {
            try self.destroy(value);
        }
    }

    inline fn destroyErrorUnion(self: *Deserializer, data: anytype) DeserializationErrors!void {
        const safe_data = data catch return;
        try self.destroy(safe_data);
    }
};
