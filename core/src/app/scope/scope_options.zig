const ActionExecutor = @import("../options/action_executor.zig").ActionExecutor;
const Protocol = @import("../options/protocol.zig").Protocol;

pub const ScopeOptions = struct {
    default_action_executor: ?ActionExecutor = null,
    default_action_protocol: ?[]const u8 = null,
};
