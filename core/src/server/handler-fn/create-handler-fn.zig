const std = @import("std");

const RequestHeaders = @import("../../message-headers/request-headers.zig").RequestHeaders;
const serializeMessageHeaders = @import("../../message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const Deserializer = @import("../../serializer/deserializer.zig").Deserializer;
const Serializer = @import("../../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../../serializer/counting-serializer.zig").Serializer;
const HandlerFn = @import("handler-fn.zig").HandlerFn;
const Server = @import("../server.zig").Server;

const Context = @import("../context/context.zig").Context;
const Clients = @import("../context/clients.zig").Clients;

pub fn createHandlerFn(comptime fn_impl: anytype) HandlerFn {
    const TFn = @TypeOf(fn_impl);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    const inject_context: bool = fn_info.@"fn".params[0].type == *Context;
    const TParams = comptime @Type(.{
        .@"struct" = .{
            .backing_integer = null,
            .decls = &.{},
            .fields = getParamTupleFieldsWithContext(@TypeOf(fn_impl)),
            .layout = .auto,
            .is_tuple = true,
        },
    });

    const TPayload: type = comptime if (inject_context)
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
        fn handler(
            server: *Server,
            initiated_by_connection_id: u32,
            request_headers: RequestHeaders,
            allocator: std.mem.Allocator,
            input_reader: *std.Io.Reader,
            output_writer: *std.Io.Writer,
        ) anyerror!void {
            var deserializer = Deserializer.init(allocator);
            const payload: TPayload = try deserializer.deserialize(input_reader, TPayload);
            const params: TParams = blk: {
                if (!inject_context) break :blk payload;

                const ctx = try allocator.create(Context);
                ctx.* = Context{
                    .allocator = allocator,
                    .clients = .{
                        .allocator = allocator,
                        .client_connections = server.clients,
                        .connected_clients = server.poll_to_client[0..server.connected],
                        .broadcast_job_queue = server.broadcast_job_queue,
                        .sender_id = initiated_by_connection_id,
                        .wakeup_fd = server.wakeup_fd,
                    },
                };

                var params: TParams = undefined;
                params.@"0" = ctx;
                const fields_with_context = comptime getParamTupleFields(@TypeOf(fn_impl));
                inline for (fields_with_context, 1..) |field, i| {
                    @field(params, std.fmt.comptimePrint("{}", .{i})) = @field(payload, field.name);
                }

                break :blk params;
            };

            const output = @call(.always_inline, fn_impl, params);

            try serializeMessageHeaders(
                output_writer,
                .{
                    .Response = .{
                        .version = request_headers.version,
                        .msg_type = .Response,
                        .request_id = request_headers.request_id,
                        .payload_len = try CountingSerializer.serialize(fn_info.@"fn".return_type.?, output),
                    },
                },
            );
            try Serializer.serialize(fn_info.@"fn".return_type.?, output_writer, output);

            // payload MUST be destroyed AFTER output serialization is complete in case pointers from payload are used in output
            try deserializer.destroy(payload);
            if (inject_context) allocator.destroy(params.@"0"); // context must be destroyed explicitly to avoid deserializer trying to load in all its fields
        }
    }.handler;
}

pub fn getParamTupleFields(comptime TFn: type) []std.builtin.Type.StructField {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    const inject_context: bool = fn_info.@"fn".params[0].type == *Context;
    const fields_len = if (inject_context) fn_info.@"fn".params.len - 1 else fn_info.@"fn".params.len;

    var fields: [fields_len]std.builtin.Type.StructField = undefined;
    const params = if (inject_context) fn_info.@"fn".params[1..] else fn_info.@"fn".params;

    for (params, 0..) |param, idx| {
        if (param.type == Context or param.type == *Context)
            @compileError("Context must be the first parameter if injected");

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

pub fn getParamTupleFieldsWithContext(comptime TFn: type) []std.builtin.Type.StructField {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    var fields: [fn_info.@"fn".params.len]std.builtin.Type.StructField = undefined;
    for (fn_info.@"fn".params, 0..) |param, idx| {
        if (idx != 0) {
            if (param.type == Context or param.type == *Context)
                @compileError("Context must be the first parameter if injected");
        } else if (param.type == Context) {
            @compileError("Context must be injected as a pointer");
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
