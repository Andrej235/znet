const std = @import("std");
const BroadcastHandlerFn = @import("./broadcast-handler-fn.zig").BroadcastHandlerFn;
const Client = @import("../client.zig").Client;
const Deserializer = @import("../../serializer/deserializer.zig").Deserializer;

pub fn createBroadcastHandlerFn(comptime fn_impl: anytype) BroadcastHandlerFn {
    const TFn = @TypeOf(fn_impl);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");
    const TParams = comptime @Type(.{
        .@"struct" = .{
            .backing_integer = null,
            .decls = &.{},
            .fields = getParamTupleFields(@TypeOf(fn_impl)),
            .layout = .auto,
            .is_tuple = true,
        },
    });

    return struct {
        pub fn handler(
            client: *Client,
            allocator: std.mem.Allocator,
            input_reader: *std.io.Reader,
        ) anyerror!void {
            _ = client;

            var deserializer = Deserializer.init(allocator);
            const params = try deserializer.deserialize(input_reader, TParams);
            @call(.always_inline, fn_impl, params);
        }
    }.handler;
}

pub fn getParamTupleFields(comptime TFn: type) []std.builtin.Type.StructField {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    var fields: [fn_info.@"fn".params.len]std.builtin.Type.StructField = undefined;
    for (fn_info.@"fn".params, 0..) |param, idx| {
        if (param.type) |T| {
            fields[idx] = .{
                .name = std.fmt.comptimePrint("{}", .{idx}),
                .type = T,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }
    }

    return &fields;
}
