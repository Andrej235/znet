const std = @import("std");

const ActionExecutor = @import("action.zig").ActionExecutor;
const RuntimeScope = @import("runtime_scope.zig").RuntimeScope;
const ResolvedScopeOptions = @import("scope.zig").ResolvedScopeOptions;
const ActionId = @import("action.zig").ActionId;

pub const AppOptions = struct {
    default_action_executor: ActionExecutor = .worker_pool,
};

pub fn App(comptime scopes: anytype, comptime options: AppOptions) type {
    const scopes_type_info = @typeInfo(@TypeOf(scopes));
    if (scopes_type_info != .@"struct" or !scopes_type_info.@"struct".is_tuple) {
        @compileError("App scopes must be a tuple containing scope definitions");
    }

    const scope_fields = scopes_type_info.@"struct".fields;
    // scope type validation
    for (scope_fields, 0..) |field, i| {
        const Scope = @field(scopes, field.name);

        if (!@hasDecl(Scope, "compile")) {
            @compileError(std.fmt.comptimePrint("Scope at index {} does not have a compile() function, did you forget to make it public?", .{i}));
        }

        const compile_fn = @field(Scope, "compile");
        const compile_fn_type_info = @typeInfo(@TypeOf(compile_fn));

        if (compile_fn_type_info != .@"fn") {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a compile declaration that is not a function", .{i}));
        }

        if (compile_fn_type_info.@"fn".return_type != []const RuntimeScope) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a compile function that does not return RuntimeScope", .{i}));
        }

        if (compile_fn_type_info.@"fn".params.len != 1) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a compile function that does not take exactly one parameter", .{i}));
        }

        if (compile_fn_type_info.@"fn".params[0].type != ResolvedScopeOptions) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a compile function whose parameter is not of type ResolvedScopeOptions", .{i}));
        }

        if (!@hasDecl(Scope, "flatten")) {
            @compileError(std.fmt.comptimePrint("Scope at index {} does not have a flatten() function, did you forget to make it public?", .{i}));
        }

        const flatten_fn = @field(Scope, "flatten");
        const flatten_fn_type_info = @typeInfo(@TypeOf(flatten_fn));

        if (flatten_fn_type_info != .@"fn") {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a flatten declaration that is not a function", .{i}));
        }

        if (flatten_fn_type_info.@"fn".return_type != []const type) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a flatten function that does not return []const type", .{i}));
        }

        if (flatten_fn_type_info.@"fn".params.len != 0) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a flatten function that takes parameters", .{i}));
        }

        if (!@hasDecl(Scope, "lookupAction")) {
            @compileError(std.fmt.comptimePrint("Scope at index {} does not have a lookupAction() function, did you forget to make it public?", .{i}));
        }

        const lookup_fn = @field(Scope, "lookupAction");
        const lookup_fn_type_info = @typeInfo(@TypeOf(lookup_fn));

        if (lookup_fn_type_info != .@"fn") {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a lookupAction declaration that is not a function", .{i}));
        }

        if (lookup_fn_type_info.@"fn".return_type != ?u16) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a lookupAction function that does not return ?u16", .{i}));
        }

        if (lookup_fn_type_info.@"fn".params.len != 1) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a lookupAction function that does not take exactly one parameter", .{i}));
        }

        if (!@hasDecl(Scope, "scope_name")) {
            @compileError(std.fmt.comptimePrint("Scope at index {} does not have a scope_name declaration, did you forget to make it public?", .{i}));
        }

        const scope_name = @field(Scope, "scope_name");
        if (@TypeOf(scope_name) != []const u8) {
            @compileError(std.fmt.comptimePrint("Scope at index {} has a scope_name declaration that is not of type []const u8", .{i}));
        }

        for (scope_fields[i + 1 ..], i + 1..) |other_field, j| {
            const OtherScope = @field(scopes, other_field.name);
            if (!@hasDecl(OtherScope, "scope_name")) {
                @compileError(std.fmt.comptimePrint("Scope at index {} does not have a scope_name declaration, did you forget to make it public?", .{j}));
            }

            const other_scope_name = @field(OtherScope, "scope_name");
            if (@TypeOf(other_scope_name) != []const u8) {
                @compileError(std.fmt.comptimePrint("Scope at index {} has a scope_name declaration that is not of type []const u8", .{j}));
            }

            if (std.mem.eql(u8, scope_name, other_scope_name)) {
                @compileError(std.fmt.comptimePrint("Scopes at index {} and {} have the same name '{s}'", .{ i, j, scope_name }));
            }
        }
    }

    const flat_scopes = comptime blk: {
        var flat_scopes: []const type = &[_]type{};
        for (scope_fields) |field| {
            const Scope = @field(scopes, field.name);
            flat_scopes = flat_scopes ++ Scope.flatten();
        }

        break :blk flat_scopes;
    };

    return struct {
        pub fn compileServerCallTable() []const RuntimeScope {
            comptime {
                var runtime_scopes: []const RuntimeScope = &[_]RuntimeScope{};

                for (scope_fields) |field| {
                    const Scope = @field(scopes, field.name);
                    const compile_fn = @field(Scope, "compile");
                    runtime_scopes = runtime_scopes ++ compile_fn(ResolvedScopeOptions.fromAppOptions(options));
                }

                return runtime_scopes;
            }
        }

        pub fn actionToId(comptime action_fn: anytype) ActionId {
            comptime {
                const action_method_type_info = @typeInfo(@TypeOf(action_fn));
                if (action_method_type_info != .@"fn") {
                    @compileError("actionToId only accepts function pointers");
                }

                for (flat_scopes, 0..) |TScope, scope_idx| {
                    const lookup_fn = @field(TScope, "lookupAction");
                    if (lookup_fn(action_fn)) |action_idx| {
                        return .{
                            .scope_idx = scope_idx,
                            .action_idx = action_idx,
                        };
                    }
                }

                @compileError("No action found with the provided method");
            }
        }
    };
}
