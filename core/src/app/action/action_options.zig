const ActionExecutor = @import("../options/action_executor.zig").ActionExecutor;
const Protocol = @import("../options/protocol.zig").Protocol;

pub const ActionOptions = struct {
    executor: ?ActionExecutor = null,
    protocol: ?[]const Protocol = null,
};
