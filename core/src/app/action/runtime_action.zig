const ActionHandler = @import("./action_handler.zig").ActionHandler;

const ActionExecutor = @import("../options/action_executor.zig").ActionExecutor;

pub const RuntimeAction = struct {
    path: []const u8,
    executor: ActionExecutor,
    handler: ActionHandler,
};
