const std = @import("std");

const Protocol = @import("../options/protocol.zig").Protocol;
const ParamKind = @import("../params/param_kind.zig").ParamKind;

const RuntimeAction = @import("runtime_action.zig").RuntimeAction;
const ResolvedScopeOptions = @import("../scope/resolved_scope_options.zig").ResolvedScopeOptions;
const ActionOptions = @import("action_options.zig").ActionOptions;

const createActionHandler = @import("./action_handler.zig").createActionHandler;

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

/// Validates that the handler function of an action is compatible with the action's protocol and path parameters,
/// and that the path parameters defined in the handler function match the path parameters defined in the action's path.
/// Throws compile errors with detailed messages if any issues are found.
fn validateActionParams(comptime handler_fn: anytype, comptime protocol: []const Protocol, absolute_path: []const u8) void {
    comptime {
        if (protocol.len == 0) {
            @compileError("Protocol must be specified for action: " ++ absolute_path);
        }

        const handler_fn_type_info = @typeInfo(@TypeOf(handler_fn)).@"fn"; // handler_fn must be a function, enforced by Action
        const params = handler_fn_type_info.params;

        var body: ?type = null;
        var query: ?type = null;
        var path: ?type = null;

        for (params) |param| {
            const T = param.type orelse continue;

            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type")) {
                const param_kind: ParamKind = @field(T, "param_kind");
                const TInnerParam: type = @field(T, "Type");

                switch (param_kind) {
                    .body => {
                        if (body != null) {
                            @compileError(std.fmt.comptimePrint("Multiple body parameters are not allowed in action handler functions. Try wrapping them in a struct. Found multiple in action at {s}", .{absolute_path}));
                        }

                        body = TInnerParam;
                    },
                    .query => {
                        if (query != null) {
                            @compileError(std.fmt.comptimePrint("Multiple query parameters are not allowed in action handler functions. Try wrapping them in a struct. Found multiple in action at {s}", .{absolute_path}));
                        }

                        query = TInnerParam;
                    },
                    .path => {
                        if (path != null) {
                            @compileError(std.fmt.comptimePrint("Multiple path parameters are not allowed in action handler functions. Try wrapping them in a struct. Found multiple in action at {s}", .{absolute_path}));
                        }

                        path = TInnerParam;
                    },
                }
            }
        }

        const expected_path_params = blk: {
            var res: []const []const u8 = &[_][]const u8{};

            var i = 0;
            var segment_start = -1;

            @setEvalBranchQuota(999999999); // todo: find a way to avoid this
            while (i < absolute_path.len) : (i += 1) {
                const c = absolute_path[i];

                switch (c) {
                    '/' => {
                        if (segment_start != -1) {
                            // opened but never closed
                            @compileError("Invalid path segment in action path: " ++ absolute_path);
                        }
                    },

                    '{' => {
                        if (segment_start != -1) {
                            // opened twice
                            @compileError("Invalid path segment in action path: " ++ absolute_path);
                        }

                        segment_start = i + 1;
                    },

                    '}' => {
                        if (segment_start == -1) {
                            // not inside a segment, closed without opening
                            @compileError("Invalid path segment in action path: " ++ absolute_path);
                        }

                        const param_name = absolute_path[segment_start..i];
                        if (param_name.len == 0) {
                            @compileError("Empty path parameter name in action path: " ++ absolute_path);
                        }

                        var a = [_][]const u8{param_name};
                        res = res ++ @as([]const []const u8, a[0..]);
                        segment_start = -1;
                    },

                    else => {
                        if (segment_start == -1) {
                            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '~') {
                                @compileError(std.fmt.comptimePrint("Invalid character '{s}' in action path: {s}", .{ [_]u8{c}, absolute_path }));
                            }
                        }
                    },
                }
            }

            if (segment_start != -1) {
                // opened but never closed
                @compileError("Invalid path segment in action path: " ++ absolute_path);
            }

            break :blk res;
        };

        if (path) |TPath| {
            const path_type_info = @typeInfo(TPath);
            if (path_type_info != .@"struct") {
                @compileError(std.fmt.comptimePrint("Path parameter type must be a struct in action at {s}", .{absolute_path}));
            }

            const found_path_params = path_type_info.@"struct".fields;
            if (found_path_params.len != expected_path_params.len) {
                if (found_path_params.len < expected_path_params.len) {
                    for (expected_path_params) |value| {
                        var found = false;
                        for (found_path_params) |field| {
                            if (std.mem.eql(u8, field.name, value)) {
                                found = true;
                                break;
                            }
                        }

                        if (!found) {
                            @compileError(std.fmt.comptimePrint("Action at {s} defines an unused path parameter '{s}'", .{ absolute_path, value }));
                        }
                    }
                }

                for (found_path_params) |field| {
                    var found = false;
                    for (expected_path_params) |value| {
                        if (std.mem.eql(u8, field.name, value)) {
                            found = true;
                            break;
                        }
                    }

                    if (!found) {
                        @compileError(std.fmt.comptimePrint("Path parameter struct in action at {s} defines an extra field '{s}' that is not defined in the action's path", .{ absolute_path, field.name }));
                    }
                }
            }

            var matched_count = 0;
            for (expected_path_params) |value| {
                var found = false;
                for (found_path_params) |field| {
                    if (std.mem.eql(u8, field.name, value)) {
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    @compileError(std.fmt.comptimePrint("Action at {s} defines an unused path parameter '{s}'", .{ absolute_path, value }));
                }

                matched_count += 1;
            }
        } else {
            if (expected_path_params.len > 0) { // it's missing all params, but just report the first one to avoid overwhelming users with errors
                @compileError(std.fmt.comptimePrint("Action at {s} defines an unused path parameter '{s}'", .{ absolute_path, expected_path_params[0] }));
            }
        }
    }
}
