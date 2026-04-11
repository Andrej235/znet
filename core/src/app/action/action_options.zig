const ActionExecutor = @import("../options/action_executor.zig").ActionExecutor;
const Protocol = @import("../options/protocol.zig").Protocol;
const HttpMethod = @import("../../http/http.zig").Method;

pub const ActionOptions = struct {
    executor: ?ActionExecutor = null,
    protocol: ?[]const Protocol = null,
    http_method: ?HttpMethod = null,
};
