const RuntimeAction = @import("runtime_action.zig").RuntimeAction;
const ResolvedScopeOptions = @import("scope.zig").ResolvedScopeOptions;

const createHandlerFn = @import("../server/handler_fn/create_handler_fn.zig").createHandlerFn;

pub const ActionExecutor = enum {
    io,
    worker_pool,
};

pub const ActionOptions = struct {
    executor: ActionExecutor = .io,
};

pub fn Action(comptime name: []const u8, comptime handler: anytype, comptime options: ActionOptions) type {
    _ = options;

    return struct {
        pub const action_name = name;

        pub fn compile(scope_options: ResolvedScopeOptions) RuntimeAction {
            return RuntimeAction{
                .path = scope_options.path ++ "/" ++ name,
                .handler = createHandlerFn(handler),
            };
        }
    };
}
