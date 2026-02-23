const std = @import("std");

const RuntimeScope = @import("runtime_scope.zig").RuntimeScope;
const ActionExecutor = @import("action.zig").ActionExecutor;
const AppOptions = @import("app.zig").AppOptions;

const ScopeOptions = struct {
    default_action_executor: ?ActionExecutor = null,
};

const ResolvedScopeOptions = struct {
    default_action_executor: ActionExecutor,

    pub fn resolve(options: ScopeOptions, app_options: AppOptions) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = options.default_action_executor orelse app_options.default_action_executor,
        };
    }
};

pub fn Scope(comptime name: []const u8, comptime children: anytype, comptime options: ScopeOptions) type {
    _ = children;
    _ = options;

    return struct {
        pub const scope_name = name;

        pub fn compile(app_options: AppOptions) RuntimeScope {
            _ = app_options;
        }
    };
}
