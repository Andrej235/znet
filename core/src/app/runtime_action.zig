// todo:?
// to unify broadcast and server handlers maybe we can pass them a different dependency injection container?
// both would have the same function definition, and via some kind of dynamicaly resolved dependencies (e.g. for server context) we can 'pass' runtime data to the handlers
// another option is to split this into two different handler types, one for server and one for broadcast, but that would be less elegant and more code to maintain
const HandlerFn = @import("../server/handler_fn/handler_fn.zig").HandlerFn;

const ActionExecutor = @import("action.zig").ActionExecutor;

pub const RuntimeAction = struct {
    path: []const u8,
    executor: ActionExecutor,
    handler: HandlerFn,
};
