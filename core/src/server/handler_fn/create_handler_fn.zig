const std = @import("std");

const Body = @import("../../app/params/body_param.zig").Body;
const ParamKind = @import("../../app/params/param_kind.zig").ParamKind;

const RequestHeaders = @import("../../message_headers/request_headers.zig").RequestHeaders;
const serializeMessageHeaders = @import("../../message_headers/serialize_message_headers.zig").serializeMessageHeaders;
const Deserializer = @import("../../serializer/deserializer.zig").Deserializer;
const Serializer = @import("../../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../../serializer/counting_serializer.zig").Serializer;
const HandlerFn = @import("handler_fn.zig").HandlerFn;
const ReactorContext = @import("../reactor.zig").ReactorContext;

const DIContainer = @import("../../dependency_injection/container.zig").Container;

pub fn createHandlerFn(comptime fn_impl: anytype, comptime di: ?DIContainer) HandlerFn {
    const TFn = @TypeOf(fn_impl);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    return struct {
        fn handler(
            context: ReactorContext,
            request_headers: RequestHeaders,
            input_reader: *std.Io.Reader,
            output_writer: *std.Io.Writer,
            input_buffer_idx: u32,
        ) anyerror!void {
            const params_info = getParamsInfo(TFn);
            const param_fields = params_info.fields;

            const TParams: type = @Type(.{
                .@"struct" = .{
                    .backing_integer = null,
                    .decls = &.{},
                    .fields = param_fields,
                    .layout = .auto,
                    .is_tuple = true,
                },
            });

            var params: TParams = undefined;

            inline for (param_fields) |field| {
                const T = field.type;
                if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type"))
                    comptime continue;

                // inject
                if (di) |d| {
                    @field(params, field.name) = comptime d.resolve(field.type);
                } else {
                    @compileError(std.fmt.comptimePrint("Cannot resolve parameter of type '{s}' because no DI container is available", .{@typeName(field.type)}));
                }
            }

            const TPayload: ?type = params_info.TBody;
            const payload_field_name = params_info.body_field_name;

            var deserializer = Deserializer.init(context.allocator);
            const payload: if (TPayload) |T| T else void = if (TPayload) |T| deserializer.deserialize(input_reader, T) catch |err| {
                context.input_buffer_pool.release(input_buffer_idx);
                return err;
            } else {};
            context.input_buffer_pool.release(input_buffer_idx);

            if (payload_field_name) |name| {
                @field(params, name) = .{ .value = payload };
            }

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

            if (TPayload) |_| { // payload MUST be destroyed AFTER output serialization is complete in case pointers from payload are used in output
                try deserializer.destroy(payload);
            }
        }
    }.handler;
}

fn getParamsInfo(comptime TFn: type) struct {
    fields: []const std.builtin.Type.StructField,
    TBody: ?type,
    body_field_name: ?[]const u8,
} {
    comptime {
        const fn_info = @typeInfo(TFn).@"fn";
        var param_fields: [fn_info.params.len]std.builtin.Type.StructField = undefined;
        var TPayload: ?type = null;
        var payload_field_name: ?[]const u8 = null;

        for (fn_info.params, 0..) |param, idx| {
            if (param.type) |T| {
                const field_name = std.fmt.comptimePrint("{}", .{idx});

                param_fields[idx] = .{
                    .name = field_name,
                    .type = T,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                };

                if (@typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type")) {
                    const param_kind: ParamKind = @field(T, "param_kind");

                    switch (param_kind) {
                        .body => {
                            TPayload = @field(T, "Type");
                            payload_field_name = field_name;
                        },
                        .path => @compileError("Not implemented"),
                        .query => @compileError("Not implemented"),
                    }
                }
            }
        }

        return .{
            .fields = param_fields[0..fn_info.params.len],
            .TBody = TPayload,
            .body_field_name = payload_field_name,
        };
    }
}
