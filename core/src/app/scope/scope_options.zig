const ActionExecutor = @import("../options/action_executor.zig").ActionExecutor;
const Protocol = @import("../options/protocol.zig").Protocol;
const DIContainer = @import("../../dependency_injection/container.zig").Container;

pub const ScopeOptions = struct {
    default_action_executor: ?ActionExecutor = null,
    default_action_protocol: ?[]const u8 = null,
    di: ?DIContainer = null,
};
