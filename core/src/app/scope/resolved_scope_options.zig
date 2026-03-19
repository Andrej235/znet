const AppOptions = @import("../app.zig").AppOptions;
const ScopeOptions = @import("scope_options.zig").ScopeOptions;

const ActionExecutor = @import("../options/action_executor.zig").ActionExecutor;
const Protocol = @import("../options/protocol.zig").Protocol;
const DIContainer = @import("../../dependency_injection/container.zig").Container;

pub const ResolvedScopeOptions = struct {
    path: []const u8,

    default_action_executor: ActionExecutor,
    default_action_protocol: []const Protocol,
    di: ?DIContainer,

    pub fn resolve(parent_options: ResolvedScopeOptions, options: ScopeOptions, name: []const u8) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = options.default_action_executor orelse parent_options.default_action_executor,
            .default_action_protocol = options.default_action_protocol orelse parent_options.default_action_protocol,
            .di = options.di orelse parent_options.di,
            .path = concatPathSegment(parent_options.path, name),
        };
    }

    pub fn fromAppOptions(app_options: AppOptions) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = app_options.default_action_executor,
            .default_action_protocol = app_options.default_action_protocol,
            .di = app_options.di,
            .path = "",
        };
    }
};

fn concatPathSegment(prefix: []const u8, segment: []const u8) []const u8 {
    if (prefix.len == 0) // root path
        return "/" ++ segment;

    if (prefix.len == 1 and prefix[0] == '/') // path is root
        return "/" ++ segment;

    if (segment.len == 0) return prefix;

    return prefix ++ "/" ++ segment;
}
