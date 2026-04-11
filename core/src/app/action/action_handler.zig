const std = @import("std");

const ActionHandlerArgs = @import("./action_handler_args.zig").ActionHandlerArgs;

const Body = @import("../../app/params/body_param.zig").Body;
const ParamKind = @import("../../app/params/param_kind.zig").ParamKind;

const Request = @import("../../server/requests/request.zig").Request;

const RequestHeaders = @import("../../message_headers/request_headers.zig").RequestHeaders;
const serializeMessageHeaders = @import("../../message_headers/serialize_message_headers.zig").serializeMessageHeaders;

const ResponseContentType = @import("../../server/requests/http.zig").ResponseContentType;

const Serializer = @import("../../serialization/serializer.zig");
const Deserializer = @import("../../serialization/deserializer.zig");

const ReactorContext = @import("../../server/reactor.zig").ReactorContext;
const BufferPool = @import("../../utils/buffer_pool.zig").BufferPool;
const Waker = @import("../../waker/waker.zig");
const ParamIterator = @import("../router.zig").Router.ParamIterator;
const ContentType = @import("../../server/requests/http.zig").ContentType;

const Logger = @import("../../logger/logger.zig").Logger.scoped(.action_handler);

const DIContainer = @import("../../dependency_injection/container.zig").Container;

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    waker: Waker,

    body: ?[]const u8,
    body_content_type: ?ContentType,

    output_writer: *std.Io.Writer,
    accepts: ?[]const u8,

    param_iterator: ParamIterator,
    query: ?[]const u8,
};

/// returns the length of the serialized output
pub const ActionHandler = *const fn (context: RequestContext) anyerror!usize;

pub fn createActionHandler(comptime callback: anytype, comptime path: []const u8, comptime di: ?DIContainer) ActionHandler {
    const TFn = @TypeOf(callback);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    return struct {
        fn handler(context: RequestContext) anyerror!usize {
            var arena = std.heap.ArenaAllocator.init(context.allocator);

            const args = try ActionHandlerArgs(@TypeOf(callback), path, di)
                .getArgs(arena.allocator(), &context);

            const output = @call(.always_inline, callback, args);

            const response_content_type = if (context.accepts) |accepts| (ResponseContentType.fromAcceptHeader(accepts) orelse ResponseContentType.json) else ResponseContentType.json;
            const bytes_written = try Serializer.countForContentType(fn_info.@"fn".return_type.?, response_content_type, output);
            try Serializer.toContentType(fn_info.@"fn".return_type.?, response_content_type, context.output_writer, output);

            // freeing the memory allocated by the arena is safe after serializing because the serializer will need to copy any data it needs into the output writer anyways
            arena.deinit();

            return bytes_written;
        }
    }.handler;
}
