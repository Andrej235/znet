const std = @import("std");

const RequestHeaders = @import("../message-headers/request-header.zig").RequestHeader;
const serializeMessageHeader = @import("../message-headers/serialize-message-header.zig").serializeMessageHeader;
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const Serializer = @import("../serializer/serializer.zig").Serializer;
const HandlerFn = @import("handler-fn.zig").HandlerFn;

pub fn createHandlerFn(comptime fn_impl: anytype) HandlerFn {
    return struct {
        fn handler(request_headers: RequestHeaders, allocator: std.mem.Allocator, input_reader: *std.Io.Reader, output_writer: *std.Io.Writer) anyerror!void {
            const TFn = @TypeOf(fn_impl);
            const fn_info = @typeInfo(TFn);
            if (fn_info != .@"fn") @compileError("Expected function type");

            const TInput = comptime @Type(.{
                .@"struct" = .{
                    .backing_integer = null,
                    .decls = &.{},
                    .fields = fields: {
                        var fields: [fn_info.@"fn".params.len]std.builtin.Type.StructField = undefined;
                        for (fn_info.@"fn".params, 0..) |param, idx| {
                            if (param.type) |t| {
                                fields[idx] = .{
                                    .name = std.fmt.comptimePrint("{}", .{idx}),
                                    .type = t,
                                    .default_value_ptr = null,
                                    .is_comptime = false,
                                    .alignment = @alignOf(t),
                                };
                            }
                        }

                        break :fields &fields;
                    },
                    .layout = .auto,
                    .is_tuple = true,
                },
            });

            var deserializer = Deserializer.init(allocator);
            const params = try deserializer.deserialize(input_reader, TInput);
            const res = @call(.always_inline, fn_impl, params);

            try serializeMessageHeader(
                output_writer,
                .{
                    .Response = .{
                        .version = request_headers.version,
                        .msg_type = .Response,
                        .request_id = request_headers.request_id,
                        .payload_len = 0, // TODO: update later
                    },
                },
            );
            try Serializer.serialize(fn_info.@"fn".return_type.?, output_writer, res);
        }
    }.handler;
}
