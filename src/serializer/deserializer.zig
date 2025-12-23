const std = @import("std");

pub const Deserializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Deserializer {
        return Deserializer{
            .allocator = allocator,
        };
    }

    pub fn deserialize(self: *Deserializer, reader: anytype, comptime T: type) !T {
        const info = @typeInfo(T);

        return switch (info) {
            .@"struct" => try self.deserializeStruct(reader, T),
            .array => try self.deserializeArray(reader, T),
            .pointer => try self.deserializePointer(reader, T),
            .optional => try self.deserializeOptional(reader, T),
            .bool => try self.deserializeBool(reader),
            .int => try self.deserializeInt(reader, T),
            .comptime_int => try self.deserializeComptimeInt(reader),
            .float => try self.deserializeFloat(reader, T),
            .comptime_float => try self.deserializeComptimeFloat(reader),
            .@"enum" => try self.deserializeEnum(reader, T),
            .@"fn" => @compileError("Functions cannot be serialized"),
            .@"opaque" => @compileError("Opaque types cannot be serialized due to lack of type information at compile time"),
            else => @compileError("Unhandled data " ++ @typeName(T) ++ "\n"),
        };
    }

    inline fn deserializeStruct(self: *Deserializer, reader: anytype, comptime TStruct: type) !TStruct {
        const info = @typeInfo(TStruct).@"struct";
        var instance: TStruct = undefined;

        inline for (info.fields) |field| {
            const field_value = try self.deserialize(reader, field.type);
            @field(instance, field.name) = field_value;
        }
        return instance;
    }

    inline fn deserializeArray(self: *Deserializer, reader: anytype, comptime TArray: type) !TArray {
        const array_info = @typeInfo(TArray).array;
        const len = array_info.len;
        var instance: TArray = undefined;

        inline for (0..len) |i| {
            const element = try self.deserialize(reader, array_info.child);
            instance[i] = element;
        }
        return instance;
    }

    inline fn deserializePointer(self: *Deserializer, reader: anytype, comptime TPointer: type) !TPointer {
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
                @compileError("C pointers are not supported");
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

    inline fn deserializeOptional(self: *Deserializer, reader: anytype, comptime TOptional: type) !TOptional {
        const optional_info = @typeInfo(TOptional).optional;
        const is_some = try self.deserializeBool(reader);
        if (is_some) {
            const value = try self.deserialize(reader, optional_info.child);
            return value;
        } else {
            return null;
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

    inline fn deserializeInt(_: *Deserializer, reader: anytype, comptime TInt: type) !TInt {
        return try reader.readInt(TInt, .big);
    }

    inline fn deserializeComptimeInt(_: *Deserializer, reader: anytype) !comptime_int {
        return try reader.readInt(i32, .big);
    }

    inline fn deserializeFloat(_: *Deserializer, reader: anytype, comptime T: type) !T {
        const TURepresentation = @Type(.{
            .int = .{
                .signedness = .unsigned,
                .bits = @sizeOf(T) * 8,
            },
        });

        const int_value: TURepresentation = try reader.readInt(TURepresentation, .big);
        return @bitCast(int_value);
    }

    inline fn deserializeComptimeFloat(self: *Deserializer, reader: anytype) !comptime_float {
        return self.deserializeFloat(reader, f32);
    }

    inline fn deserializeEnum(self: *Deserializer, reader: anytype, comptime T: type) !T {
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
