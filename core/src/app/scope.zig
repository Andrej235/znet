const std = @import("std");

const RuntimeScope = @import("runtime_scope.zig").RuntimeScope;
const RuntimeAction = @import("runtime_action.zig").RuntimeAction;
const ActionExecutor = @import("action.zig").ActionExecutor;
const AppOptions = @import("app.zig").AppOptions;

pub const ScopeOptions = struct {
    default_action_executor: ?ActionExecutor = null,
};

pub const ResolvedScopeOptions = struct {
    path: []const u8,

    default_action_executor: ActionExecutor,

    pub fn resolve(parent_options: ResolvedScopeOptions, options: ScopeOptions, name: []const u8) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = options.default_action_executor orelse parent_options.default_action_executor,
            .path = parent_options.path ++ "/" ++ name,
        };
    }

    pub fn fromAppOptions(app_options: AppOptions) ResolvedScopeOptions {
        return ResolvedScopeOptions{
            .default_action_executor = app_options.default_action_executor,
            .path = "",
        };
    }
};

pub fn Scope(comptime name: []const u8, comptime children: anytype, comptime options: ScopeOptions) type {
    const childern_type_info = @typeInfo(@TypeOf(children));
    if (childern_type_info != .@"struct" or !childern_type_info.@"struct".is_tuple) {
        @compileError("Scope children must be a tuple containing scope and action definitions");
    }

    const children_fields = childern_type_info.@"struct".fields;
    for (children_fields, 0..) |field, i| {
        const Child = @field(children, field.name);
        const child_name = getName(Child) orelse @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} does not have a name", .{ i, name }));

        if (!@hasDecl(Child, "compile"))
            @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} does not have a compile() function, did you forget to make it public?", .{ i, name }));

        if (isScope(Child)) {
            // ok
        } else if (isAction(Child)) {
            // ok
        } else @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} is neither a scope nor an action", .{ i, name }));

        for (children_fields[i + 1 ..], i + 1..) |other_field, j| {
            const OtherChild = @field(children, other_field.name);
            const other_name = getName(OtherChild) orelse @compileError(std.fmt.comptimePrint("Child at index {} of scope {s} does not have a name", .{ j, name }));

            if (std.mem.eql(u8, child_name, other_name)) {
                @compileError(std.fmt.comptimePrint("Children of {s} at index {} and {} have the same name '{s}'", .{ name, i, j, child_name }));
            }
        }
    }

    return struct {
        pub const scope_name = name;

        pub fn compile(parent_options: ResolvedScopeOptions) []const RuntimeScope {
            const resolved_options = ResolvedScopeOptions.resolve(parent_options, options, name);

            var self: RuntimeScope = &[_]RuntimeAction{};
            var runtime_scopes: []const RuntimeScope = &[_]RuntimeScope{};
            for (children_fields) |field| {
                const Child = @field(children, field.name);

                if (isScope(Child)) {
                    const child_runtime_scopes = Child.compile(resolved_options);
                    runtime_scopes = runtime_scopes ++ child_runtime_scopes;
                } else if (isAction(Child)) {
                    const runtime_action = Child.compile(resolved_options);
                    self = self ++ @as(RuntimeScope, &.{runtime_action});
                } else unreachable;
            }

            return &[_]RuntimeScope{self} ++ runtime_scopes;
        }
    };
}

fn getName(comptime Child: type) ?[]const u8 {
    if (@hasDecl(Child, "scope_name")) {
        const scope_name = @field(Child, "scope_name");
        if (@TypeOf(scope_name) == []const u8) {
            return scope_name;
        }
    }

    if (@hasDecl(Child, "action_name")) {
        const action_name = @field(Child, "action_name");
        if (@TypeOf(action_name) == []const u8) {
            return action_name;
        }
    }

    return null;
}

fn isScope(comptime Child: type) bool {
    const compile_fn = @field(Child, "compile");
    const compile_fn_type_info = @typeInfo(@TypeOf(compile_fn));

    if (compile_fn_type_info != .@"fn")
        return false;

    if (compile_fn_type_info.@"fn".return_type != []const RuntimeScope)
        return false;

    if (compile_fn_type_info.@"fn".params.len != 1)
        return false;

    const param_types = compile_fn_type_info.@"fn".params;
    if (param_types[0].type != ResolvedScopeOptions)
        return false;

    if (!@hasDecl(Child, "scope_name"))
        return false;

    const scope_name = @field(Child, "scope_name");
    if (@TypeOf(scope_name) != []const u8)
        return false;

    return true;
}

fn isAction(comptime Child: type) bool {
    const compile_fn = @field(Child, "compile");
    const compile_fn_type_info = @typeInfo(@TypeOf(compile_fn));

    if (compile_fn_type_info != .@"fn")
        return false;

    if (compile_fn_type_info.@"fn".return_type != RuntimeAction)
        return false;

    if (compile_fn_type_info.@"fn".params.len != 1)
        return false;

    const param_types = compile_fn_type_info.@"fn".params;
    if (param_types[0].type != ResolvedScopeOptions)
        return false;

    if (!@hasDecl(Child, "action_name"))
        return false;

    const action_name = @field(Child, "action_name");
    if (@TypeOf(action_name) != []const u8)
        return false;

    return true;
}
