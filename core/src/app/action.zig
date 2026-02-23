const RuntimeAction = @import("runtime_action.zig").RuntimeAction;

pub const ActionExecutor = enum {
    io,
    worker_pool,
};

pub const ActionOptions = struct {
    executor: ActionExecutor = .io,
};

pub fn Action(comptime name: []const u8, comptime handler: anytype, comptime options: ActionOptions) type {
    _ = options;
    _ = handler;
    _ = name;
}
