const std = @import("std");

const DIContainer = @import("../../dependency_injection/container.zig").Container;
const RequestContext = @import("../../requests/request_context.zig").RequestContext;
const ActionHandlerArgs = @import("./action_handler_args.zig").ActionHandlerArgs;

const ResponseContentType = @import("../../requests/http.zig").ResponseContentType;
const Serializer = @import("../../serialization/serializer.zig");

const Logger = @import("../../logger/logger.zig").Logger.scoped(.action_handler);

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
