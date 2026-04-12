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

// todo: make action_handler_args return a union of either the args or a pointer to errors
// these errors would be stack allocated aboe the line where we get the args and passed in as a pointer
// getargs then fills in the error struct if it fails to validate path and query params, (maybe body as well?)
// return 400 if the error struct is filled in, otherwise proceed normally

// todo:? seeing as the errors struct would be created here we could make it have N error slots up to M
// where N is the number of possible errors (path params count + query params count) and M is some max we set (maybe 8/16? or defined in config)

pub fn createActionHandler(comptime callback: anytype, comptime path: []const u8, comptime di: ?DIContainer) ActionHandler {
    const TFn = @TypeOf(callback);
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    return struct {
        fn handler(context: RequestContext) anyerror!usize {
            var arena = std.heap.ArenaAllocator.init(context.allocator);

            const TArgs = ActionHandlerArgs(@TypeOf(callback), path, di);
            var args_errors = TArgs.initErrors();
            const parse_args_result = TArgs.getArgs(arena.allocator(), &context, &args_errors);

            var bytes_written: usize = 0;

            switch (parse_args_result) {
                .success => |args| {
                    const output = @call(.always_inline, callback, args);

                    const TOut = fn_info.@"fn".return_type.?;
                    const response = Response(TOut){
                        .http = .init(http.StatusCode.ok, context.connection, context.accepts, output),
                    };
                    bytes_written = try ResponseWriter.write(TOut, response, context.output_writer);
                },
                .failure => |errors| {
                    const response = Response(TArgs.ErrorsResult){
                        .http = .init(http.StatusCode.bad_request, context.connection, context.accepts, errors),
                    };
                    bytes_written = try ResponseWriter.write(TArgs.ErrorsResult, response, context.output_writer);
                },
            }

            // freeing the memory allocated by the arena is safe after serializing because the serializer will need to copy any data it needs into the output writer anyways
            arena.deinit();

            return bytes_written;
        }
    }.handler;
}
