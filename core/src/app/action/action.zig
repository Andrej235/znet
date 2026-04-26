const std = @import("std");

const Protocol = @import("../options/protocol.zig").Protocol;
const ParamKind = @import("../params/param_kind.zig").ParamKind;

const RuntimeAction = @import("runtime_action.zig").RuntimeAction;
const ResolvedScopeOptions = @import("../scope/resolved_scope_options.zig").ResolvedScopeOptions;
const ActionOptions = @import("action_options.zig").ActionOptions;

const createActionHandler = @import("./action_handler.zig").createActionHandler;
const validateActionParams = @import("./validate_action_params.zig").validateActionParams;

pub const ActionName = ?@Type(.enum_literal);

pub fn Action(comptime name: ActionName, comptime handler_fn: anytype, comptime options: ActionOptions) type {
    if (@typeInfo(@TypeOf(handler_fn)) != .@"fn") {
        @compileError("Handler function must be a function");
    }

    const string_name: []const u8 = if (name) |n| @tagName(n) else "";

    return struct {
        pub const action_name = string_name;

        pub fn compile(comptime scope_options: ResolvedScopeOptions) RuntimeAction {
            const protocol = options.protocol orelse scope_options.default_action_protocol;
            const absolute_path = concatPathSegment(scope_options.path, string_name);

            // validateActionParams throws compile errors if the handler function is invalid instead of returning an error for better descriptions and richer context
            validateActionParams(handler_fn, protocol, absolute_path);

            return RuntimeAction{
                .path = absolute_path,
                .handler = createActionHandler(handler_fn, absolute_path, scope_options.di),
                .executor = options.executor orelse scope_options.default_action_executor,
                .http_method = options.http_method orelse .GET,
            };
        }
    };
}

fn concatPathSegment(comptime prefix: []const u8, comptime segment: []const u8) []const u8 {
    if (prefix.len == 0) return segment;
    if (segment.len == 0) return prefix;

    if (prefix.len == 1 and prefix[0] == '/') // path is root
        return "/" ++ segment;

    return prefix ++ "/" ++ segment;
}

const ActionValidationError = error{
    ActionMissingCompileFn,
    ActionCompileFnNotFunction,
    ActionCompileFnInvalidReturnType,
    ActionCompileFnInvalidParameterCount,
    ActionCompileFnInvalidParameterType,

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

        if (!@hasDecl(TAction, "action_name")) {
            return ActionValidationError.ActionMissingActionName;
        }

        const action_name = @field(TAction, "action_name");
        if (@TypeOf(action_name) != []const u8) {
            return ActionValidationError.ActionInvalidActionNameType;
        }
    }
}

