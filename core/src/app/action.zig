const RuntimeAction = @import("runtime_action.zig").RuntimeAction;
const ResolvedScopeOptions = @import("scope.zig").ResolvedScopeOptions;

const createHandlerFn = @import("../server/handler_fn/create_handler_fn.zig").createHandlerFn;

pub const ActionExecutor = enum {
    io,
    worker_pool,
};

pub const ActionOptions = struct {
    executor: ?ActionExecutor = null,
};

pub fn Action(comptime name: []const u8, comptime handler_fn: anytype, comptime options: ActionOptions) type {
    return struct {
        pub const action_name = name;

        pub fn compile(scope_options: ResolvedScopeOptions) RuntimeAction {
            return RuntimeAction{
                .path = scope_options.path ++ "/" ++ name,
                .handler = createHandlerFn(handler_fn),
                .executor = options.executor orelse scope_options.default_action_executor,
            };
        }

        pub fn compare(other_handler_fn: anytype) bool {
            return comptime handler_fn == other_handler_fn;
        }
    };
}

pub const ActionId = struct {
    scope_idx: u16,
    action_idx: u16,
};
