const std = @import("std");
const http = @import("../../http/http.zig");

const DIContainer = @import("../../dependency_injection/container.zig").Container;
const RequestContext = @import("../../requests/request_context.zig").RequestContext;
const ActionHandlerArgs = @import("./action_handler_args.zig").ActionHandlerArgs;

const Serializer = @import("../../serialization/serializer.zig");

const Logger = @import("../../logger/logger.zig").Logger.scoped(.action_handler);

const ResponseWriter = @import("../../responses/response_writer.zig").ResponseWriter;
const Response = @import("../../responses/response.zig").Response;

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

            const TOut = fn_info.@"fn".return_type.?;
            const response = Response(TOut){
                .http = .init(http.StatusCode.ok, context.connection, context.accepts, output),
            };
            const bytes_written = try ResponseWriter.write(TOut, response, context.output_writer);

            // freeing the memory allocated by the arena is safe after serializing because the serializer will need to copy any data it needs into the output writer anyways
            arena.deinit();

            return bytes_written;
        }
    }.handler;
}
