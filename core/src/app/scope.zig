const std = @import("std");

const validateAction = @import("action.zig").validateAction;

const RuntimeScope = @import("runtime_scope.zig").RuntimeScope;
const RuntimeAction = @import("runtime_action.zig").RuntimeAction;
const ActionExecutor = @import("action.zig").ActionExecutor;
const AppOptions = @import("app.zig").AppOptions;
const ActionId = @import("action.zig").ActionId;

pub const ScopeOptions = struct {
    default_action_executor: ?ActionExecutor = null,
};

pub const ResolvedScopeOptions = struct {
    path: []const u8,

    default_action_executor: ActionExecutor,

    pub fn resolve(parent_options: ResolvedScopeOptions, options: ScopeOptions, name: []const u8) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = options.default_action_executor orelse parent_options.default_action_executor,
            .path = concatPathSegment(parent_options.path, name),
        };
    }

    pub fn fromAppOptions(app_options: AppOptions) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = app_options.default_action_executor,
            .path = "",
        };
    }
};

fn concatPathSegment(path: []const u8, segment: []const u8) []const u8 {
    if (path.len == 0) // root path
        return "/" ++ segment;

    if (segment.len == 0) return path;

    return std.fmt.comptimePrint("{s}/{s}", .{ path, segment });
}

pub const ScopeName = ?@Type(.enum_literal);

pub fn Scope(comptime name: ScopeName, comptime children: anytype, comptime options: ScopeOptions) type {
    const string_name: []const u8 = if (name) |n| @tagName(n) else "";

    const children_arr = childrenToArray(children);
    for (children_arr, 0..) |Child, i| {
        validateScope(Child) catch |scope_err| { // not a scope
            validateAction(Child) catch |action_err| { // not an action
                @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} is invalid: {s} is not a scope ({s}) nor an action ({s})", .{ i, string_name, @errorName(scope_err), @errorName(action_err) }));
            };
        };

        const child_name = getName(Child) orelse @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} does not have a name", .{ i, string_name }));

        for (children_arr[i + 1 ..], i + 1..) |OtherChild, j| {
            const other_name = getName(OtherChild) orelse @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} does not have a name", .{ j, string_name }));

            if (std.mem.eql(u8, child_name, other_name)) {
                @compileError(std.fmt.comptimePrint("Children of {s} at index {} and {} have the same name '{s}'", .{ string_name, i, j, child_name }));
            }
        }
    }

    return struct {
        pub const scope_name = string_name;

        pub fn compile(comptime parent_options: ResolvedScopeOptions) []const RuntimeScope {
            comptime {
                const resolved_options = ResolvedScopeOptions.resolve(parent_options, options, string_name);

                var self: RuntimeScope = &[_]RuntimeAction{};
                var runtime_scopes: []const RuntimeScope = &[_]RuntimeScope{};
                for (children_arr) |Child| {
                    if (isScope(Child)) {
                        const child_runtime_scopes = Child.compile(resolved_options);
                        runtime_scopes = runtime_scopes ++ child_runtime_scopes;
                    } else {
                        const runtime_action = Child.compile(resolved_options);
                        self = self ++ @as(RuntimeScope, &.{runtime_action});
                    }
                }

                return &[_]RuntimeScope{self} ++ runtime_scopes;
            }
        }

        pub fn flatten() []const type {
            comptime {
                var child_scopes: []const type = &[_]type{};
                var child_actions: []const type = &[_]type{};

                for (children_arr) |Child| {
                    if (isScope(Child)) {
                        child_scopes = child_scopes ++ Child.flatten();
                    } else {
                        child_actions = child_actions ++ &[_]type{Child};
                    }
                }

                return &[_]type{Scope(name, child_actions, options)} ++ child_scopes;
            }
        }

        /// Can ONLY be used on a flat scope, assumes all children are actions
        pub fn lookupAction(comptime handler: anytype) ?u16 {
            comptime {
                for (children_arr, 0..) |TChild, i| {
                    const lookup_fn = @field(TChild, "compare");
                    if (lookup_fn(handler))
                        return i;
                }

                return null;
            }
        }
    };
}

pub const ScopeValidationError = error{
    ScopeMissingCompileFn,
    ScopeCompileFnNotFunction,
    ScopeCompileFnInvalidReturnType,
    ScopeCompileFnInvalidParameterCount,
    ScopeCompileFnInvalidParameterType,

    ScopeMissingFlattenFn,
    ScopeFlattenFnNotFunction,
    ScopeFlattenFnInvalidReturnType,
    ScopeFlattenFnInvalidParameterCount,

    ScopeMissingLookupActionFn,
    ScopeLookupActionFnNotFunction,
    ScopeLookupActionFnInvalidReturnType,
    ScopeLookupActionFnInvalidParameterCount,

    ScopeMissingScopeName,
    ScopeInvalidScopeNameType,
};

pub fn validateScope(comptime TScope: type) !void {
    comptime {
        if (!@hasDecl(TScope, "compile")) {
            return ScopeValidationError.ScopeMissingCompileFn;
        }

        const compile_fn = @field(TScope, "compile");
        const compile_fn_type_info = @typeInfo(@TypeOf(compile_fn));

        if (compile_fn_type_info != .@"fn") {
            return ScopeValidationError.ScopeCompileFnNotFunction;
        }

        if (compile_fn_type_info.@"fn".return_type != []const RuntimeScope) {
            return ScopeValidationError.ScopeCompileFnInvalidReturnType;
        }

        if (compile_fn_type_info.@"fn".params.len != 1) {
            return ScopeValidationError.ScopeCompileFnInvalidParameterCount;
        }

        if (compile_fn_type_info.@"fn".params[0].type != ResolvedScopeOptions) {
            return ScopeValidationError.ScopeCompileFnInvalidParameterType;
        }

        if (!@hasDecl(TScope, "flatten")) {
            return ScopeValidationError.ScopeMissingFlattenFn;
        }

        const flatten_fn = @field(TScope, "flatten");
        const flatten_fn_type_info = @typeInfo(@TypeOf(flatten_fn));

        if (flatten_fn_type_info != .@"fn") {
            return ScopeValidationError.ScopeFlattenFnNotFunction;
        }

        if (flatten_fn_type_info.@"fn".return_type != []const type) {
            return ScopeValidationError.ScopeFlattenFnInvalidReturnType;
        }

        if (flatten_fn_type_info.@"fn".params.len != 0) {
            return ScopeValidationError.ScopeFlattenFnInvalidParameterCount;
        }

        if (!@hasDecl(TScope, "lookupAction")) {
            return ScopeValidationError.ScopeMissingLookupActionFn;
        }

        const lookup_fn = @field(TScope, "lookupAction");
        const lookup_fn_type_info = @typeInfo(@TypeOf(lookup_fn));

        if (lookup_fn_type_info != .@"fn") {
            return ScopeValidationError.ScopeLookupActionFnNotFunction;
        }

        if (lookup_fn_type_info.@"fn".return_type != ?u16) {
            return ScopeValidationError.ScopeLookupActionFnInvalidReturnType;
        }

        if (lookup_fn_type_info.@"fn".params.len != 1) {
            return ScopeValidationError.ScopeLookupActionFnInvalidParameterCount;
        }

        if (!@hasDecl(TScope, "scope_name")) {
            return ScopeValidationError.ScopeMissingScopeName;
        }

        const scope_name = @field(TScope, "scope_name");
        if (@TypeOf(scope_name) != []const u8) {
            return ScopeValidationError.ScopeInvalidScopeNameType;
        }
    }
}

pub fn isScope(comptime T: type) bool {
    comptime {
        validateScope(T) catch return false;
        return true;
    }
}

fn getName(comptime TChild: type) ?[]const u8 {
    if (@hasDecl(TChild, "scope_name")) {
        const scope_name = @field(TChild, "scope_name");
        if (@TypeOf(scope_name) == []const u8) {
            return scope_name;
        }
    }

    if (@hasDecl(TChild, "action_name")) {
        const action_name = @field(TChild, "action_name");
        if (@TypeOf(action_name) == []const u8) {
            return action_name;
        }
    }

    return null;
}

fn childrenToArray(comptime children: anytype) []const type {
    var arr: []const type = &[_]type{};

    const childern_type_info = @typeInfo(@TypeOf(children));
    if ((childern_type_info != .@"struct" or !childern_type_info.@"struct".is_tuple) and childern_type_info != .array and (childern_type_info != .pointer or @typeInfo(@TypeOf(children)).pointer.size != .slice)) {
        @compileError("Scope children must be a tuple, array, or a slice containing scope and action definitions");
    }

    const children_iterable = if (childern_type_info == .@"struct") childern_type_info.@"struct".fields else children;
    for (children_iterable, 0..) |field, i| {
        const Child = if (childern_type_info == .@"struct") @field(children, field.name) else children[i];
        arr = arr ++ &[_]type{Child};
    }

    return arr;
}
