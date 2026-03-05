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

pub const ActionName = ?@Type(.enum_literal);

pub fn Action(comptime name: ActionName, comptime handler_fn: anytype, comptime options: ActionOptions) type {
    const string_name: []const u8 = if (name) |n| @tagName(n) else "";

    return struct {
        pub const action_name = string_name;

        pub fn compile(comptime scope_options: ResolvedScopeOptions) RuntimeAction {
            return RuntimeAction{
                .path = concatPathSegment(scope_options.path, string_name),
                .handler = createHandlerFn(handler_fn),
                .executor = options.executor orelse scope_options.default_action_executor,
            };
        }

        pub fn compare(comptime other_handler_fn: anytype) bool {
            return comptime handler_fn == other_handler_fn;
        }
    };
}

fn concatPathSegment(comptime prefix: []const u8, comptime segment: []const u8) []const u8 {
    if (prefix.len == 0) return segment;
    if (segment.len == 0) return prefix;

    return prefix ++ "/" ++ segment;
}

pub const ActionId = struct {
    scope_idx: u16,
    action_idx: u16,
};

const ActionValidationError = error{
    ActionMissingCompileFn,
    ActionCompileFnNotFunction,
    ActionCompileFnInvalidReturnType,
    ActionCompileFnInvalidParameterCount,
    ActionCompileFnInvalidParameterType,

    ActionMissingCompareFn,
    ActionCompareFnNotFunction,
    ActionCompareFnInvalidReturnType,
    ActionCompareFnInvalidParameterCount,

    ActionMissingActionName,
    ActionInvalidActionNameType,
};

pub fn validateAction(comptime TAction: type) !void {
    comptime {
        if (!@hasDecl(TAction, "compile")) {
            return ActionValidationError.ActionMissingCompileFn;
        }

        const compile_fn = @field(TAction, "compile");
        const compile_fn_type_info = @typeInfo(@TypeOf(compile_fn));

        if (compile_fn_type_info != .@"fn") {
            return ActionValidationError.ActionCompileFnNotFunction;
        }

        if (compile_fn_type_info.@"fn".return_type != RuntimeAction) {
            return ActionValidationError.ActionCompileFnInvalidReturnType;
        }

        if (compile_fn_type_info.@"fn".params.len != 1) {
            return ActionValidationError.ActionCompileFnInvalidParameterCount;
        }

        if (compile_fn_type_info.@"fn".params[0].type != ResolvedScopeOptions) {
            return ActionValidationError.ActionCompileFnInvalidParameterType;
        }

        if (!@hasDecl(TAction, "compare")) {
            return ActionValidationError.ActionMissingCompareFn;
        }

        const compare_fn = @field(TAction, "compare");
        const compare_fn_type_info = @typeInfo(@TypeOf(compare_fn));

        if (compare_fn_type_info != .@"fn") {
            return ActionValidationError.ActionCompareFnNotFunction;
        }

        if (compare_fn_type_info.@"fn".return_type != bool) {
            return ActionValidationError.ActionCompareFnInvalidReturnType;
        }

        if (compare_fn_type_info.@"fn".params.len != 1) {
            return ActionValidationError.ActionCompareFnInvalidParameterCount;
        }

        if (!@hasDecl(TAction, "action_name")) {
            return ActionValidationError.ActionMissingActionName;
        }

        const action_name = @field(TAction, "action_name");
        if (@TypeOf(action_name) != []const u8) {
            return ActionValidationError.ActionInvalidActionNameType;
        }
    }
}
