const std = @import("std");

const validateAction = @import("../action/action.zig").validateAction;

const ScopeOptions = @import("scope_options.zig").ScopeOptions;
const ResolvedScopeOptions = @import("resolved_scope_options.zig").ResolvedScopeOptions;

const RuntimeScope = @import("runtime_scope.zig").RuntimeScope;
const RuntimeAction = @import("../action/runtime_action.zig").RuntimeAction;

pub const ScopeName = ?@Type(.enum_literal);

pub fn Scope(comptime name: ScopeName, comptime children: anytype, comptime options: ScopeOptions) type {
    const string_name: []const u8 = if (name) |n| @tagName(n) else "";

    const children_arr = childrenToArray(children);
    for (children_arr, 0..) |Child, i| {
        validateScope(Child) catch |scope_err| { // not a scope
            validateAction(Child) catch |action_err| { // not an action
                @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} is not a scope ({s}) nor an action ({s})", .{ i, string_name, @errorName(scope_err), @errorName(action_err) }));
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
    };
}

pub const ScopeValidationError = error{
    ScopeMissingCompileFn,
    ScopeCompileFnNotFunction,
    ScopeCompileFnInvalidReturnType,
    ScopeCompileFnInvalidParameterCount,
    ScopeCompileFnInvalidParameterType,

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
