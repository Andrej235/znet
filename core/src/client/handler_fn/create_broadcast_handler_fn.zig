const std = @import("std");
const BroadcastHandlerFn = @import("./broadcast_handler_fn.zig").BroadcastHandlerFn;
const Client = @import("../client.zig").Client;
const Deserializer = @import("../../serializer/deserializer.zig").Deserializer;

pub fn createBroadcastHandlerFn(comptime fn_impl: anytype) BroadcastHandlerFn {
    const TFn = @TypeOf(fn_impl);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    const inject_client: bool = fn_info.@"fn".params[0].type == *Client;
    const TParams = comptime @Type(.{
        .@"struct" = .{
            .backing_integer = null,
            .decls = &.{},
            .fields = getParamTupleFieldsWithClient(@TypeOf(fn_impl)),
            .layout = .auto,
            .is_tuple = true,
        },
    });

    const TPayload: type = comptime if (inject_client)
        @Type(.{
            .@"struct" = .{
                .backing_integer = null,
                .decls = &.{},
                .fields = getParamTupleFields(@TypeOf(fn_impl)),
                .layout = .auto,
                .is_tuple = true,
            },
        })
    else
        TParams;

    return struct {
        pub fn handler(
            client: *Client,
            allocator: std.mem.Allocator,
            input_reader: *std.io.Reader,
        ) anyerror!void {
            var deserializer = Deserializer.init(allocator);
            const payload: TPayload = try deserializer.deserialize(input_reader, TPayload);
            const params: TParams = blk: {
                if (!inject_client) break :blk payload;

                var params: TParams = undefined;
                params.@"0" = client;
                const fields_with_client = comptime getParamTupleFields(@TypeOf(fn_impl));
                inline for (fields_with_client, 1..) |field, i| {
                    @field(params, std.fmt.comptimePrint("{}", .{i})) = @field(payload, field.name);
                }

                break :blk params;
            };

            try @call(.always_inline, fn_impl, params);
            try deserializer.destroy(payload);
        }
    }.handler;
}

pub fn getParamTupleFields(comptime TFn: type) []std.builtin.Type.StructField {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    const inject_client: bool = fn_info.@"fn".params[0].type == *Client;
    const fields_len = if (inject_client) fn_info.@"fn".params.len - 1 else fn_info.@"fn".params.len;

    var fields: [fields_len]std.builtin.Type.StructField = undefined;
    const params = if (inject_client) fn_info.@"fn".params[1..] else fn_info.@"fn".params;

    for (params, 0..) |param, idx| {
        if (param.type == Client or param.type == *Client)
            @compileError("Client must be the first parameter if injected");

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

pub fn getParamTupleFieldsWithClient(comptime TFn: type) []std.builtin.Type.StructField {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    var fields: [fn_info.@"fn".params.len]std.builtin.Type.StructField = undefined;
    for (fn_info.@"fn".params, 0..) |param, idx| {
        if (idx != 0) {
            if (param.type == Client or param.type == *Client)
                @compileError("Client must be the first parameter if injected");
        } else if (param.type == Client) {
            @compileError("Client must be injected as a pointer");
        }

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
