const std = @import("std");

const RequestHeaders = @import("../../message_headers/request_headers.zig").RequestHeaders;
const serializeMessageHeaders = @import("../../message_headers/serialize_message_headers.zig").serializeMessageHeaders;
const Deserializer = @import("../../serializer/deserializer.zig").Deserializer;
const Serializer = @import("../../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../../serializer/counting_serializer.zig").Serializer;
const HandlerFn = @import("handler_fn.zig").HandlerFn;
const ReactorContext = @import("../reactor.zig").ReactorContext;

const Context = @import("../context/context.zig").Context;
const Clients = @import("../context/clients.zig").Clients;

pub fn createHandlerFn(comptime fn_impl: anytype) HandlerFn {
    const TFn = @TypeOf(fn_impl);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    const inject_context: bool = fn_info.@"fn".params.len > 0 and fn_info.@"fn".params[0].type == *Context;
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
            context: ReactorContext,
            request_headers: RequestHeaders,
            input_reader: *std.Io.Reader,
            output_writer: *std.Io.Writer,
            input_buffer_idx: u32,
        ) anyerror!void {
            var deserializer = Deserializer.init(context.allocator);
            const payload: TPayload = deserializer.deserialize(input_reader, TPayload) catch |err| {
                context.input_buffer_pool.release(input_buffer_idx);
                return err;
            };
            context.input_buffer_pool.release(input_buffer_idx);

            const params: TParams = blk: {
                if (!inject_context) break :blk payload;

                const ctx = try context.allocator.create(Context);
                ctx.* = Context{
                    .allocator = context.allocator,
                    .clients = .{
                        .allocator = context.allocator,
                        .client_connections = context.client_connections,
                        .connected_clients = context.connected_clients,
                        .sender_id = context.initiated_by_connection_id,
                        .waker = context.waker,
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
                        .flags = 0,
                        .request_id = request_headers.request_id,
                        .payload_len = try CountingSerializer.serialize(fn_info.@"fn".return_type.?, output),
                    },
                },
            );
            try Serializer.serialize(fn_info.@"fn".return_type.?, output_writer, output);

            // payload MUST be destroyed AFTER output serialization is complete in case pointers from payload are used in output
            try deserializer.destroy(payload);
            if (inject_context) context.allocator.destroy(params.@"0"); // context must be destroyed explicitly to avoid deserializer trying to load in all its fields
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
