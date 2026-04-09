const std = @import("std");

const DeserializationErrors = @import("../errors.zig").DeserializationErrors;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.form_url_encoded_deserializer);

pub const Deserializer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Deserializer {
        return Deserializer{
            .allocator = allocator,
        };
    }

    // todo: support array of values for repeated keys, e.g. tags=tag1&tags=tag2&tags=tag3
    // todo: support nested structs with dot notation in keys, e.g. user.name=John&user.age=30
    pub fn deserialize(self: *Deserializer, reader: *std.Io.Reader, comptime T: type) DeserializationErrors!T {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("FormUrlEncodedDeserializer can only deserialize into structs");
        }

        var result: T = undefined;
        const fields = info.@"struct".fields;

        inline for (fields) |field| {
            comptime if (@typeInfo(field.type) != .optional) continue;

            // initialize all optionals to null in case they are not present in the input
            // this prevents undefined behavior from uninitialized memory
            @field(result, field.name) = null;
        }
        var seen = [_]bool{false} ** fields.len;

        while (reader.takeDelimiter('&') catch |err| blk: {
            Logger.err("Failed to read key-value pair: {}", .{err});
            break :blk null;
        }) |kv| {
            const eq_index = std.mem.indexOfScalar(u8, kv, '=');
            const key = if (eq_index) |i| kv[0..i] else kv;
            const value = if (eq_index) |i| kv[i + 1 ..] else &[_]u8{};

            inline for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, key)) {
                    @field(result, field.name) = try self.deserializeValue(value, field.type);
                    seen[i] = true;
                    break;
                }
            }
        }

        inline for (seen, 0..) |s, i| {
            comptime if (@typeInfo(fields[i].type) == .optional) continue;

            if (!s) {
                Logger.err("fuuuuck: {s}", .{fields[i].name});
                return DeserializationErrors.MissingRequiredField;
            }
        }

        return result;
    }

    fn deserializeValue(self: *Deserializer, value: []const u8, T: type) DeserializationErrors!T {
        if (T == []const u8) {
            return value;
        }

        const info = @typeInfo(T);

        switch (info) {
            .int => {
                return std.fmt.parseInt(T, value, 10) catch
                    return DeserializationErrors.IntegerDeserializationFailed;
            },
            .float => {
                return std.fmt.parseFloat(T, value) catch
                    return DeserializationErrors.FloatDeserializationFailed;
            },
            .bool => {
                if (value.len == 0) {
                    return true; // presence of the key without value is treated as true
                }

                return std.mem.eql(u8, value, "true");
            },
            .@"enum" => |enum_info| {
                inline for (enum_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, value)) {
                        return @field(T, field.name);
                    }
                }

                return DeserializationErrors.InvalidUnionTag;
            },
            .optional => |optional_info| {
                if (value.len == 0) {
                    return null;
                }

                return try self.deserializeValue(value, optional_info.child);
            },
            else => @compileError(std.fmt.comptimePrint("Unsupported query parameter type: {s}", .{@typeName(T)})),
        }
    }
};
