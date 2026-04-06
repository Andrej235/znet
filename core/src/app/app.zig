const std = @import("std");

const DIContainer = @import("../dependency_injection/container.zig").Container;
const Router = @import("router.zig").Router;

const validateScope = @import("scope/scope.zig").validateScope;

const ActionExecutor = @import("options/action_executor.zig").ActionExecutor;
const Protocol = @import("options/protocol.zig").Protocol;
const RuntimeScope = @import("scope/runtime_scope.zig").RuntimeScope;
const ResolvedScopeOptions = @import("scope/resolved_scope_options.zig").ResolvedScopeOptions;
const ActionId = @import("action/action.zig").ActionId;

pub const AppOptions = struct {
    default_action_executor: ActionExecutor = .worker_pool,
    default_action_protocol: []const Protocol = &[_]Protocol{.http},
    di: ?DIContainer = null,
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

        validateScope(Scope) catch |err| {
            @compileError(std.fmt.comptimePrint("Scope at index {} is invalid: {s}", .{ i, @errorName(err) }));
        };

        const scope_name: []const u8 = @field(Scope, "scope_name"); // we already know Scope is valid

        for (scope_fields[i + 1 ..], i + 1..) |other_field, j| {
            const OtherScope = @field(scopes, other_field.name);
            const other_scope_name = getScopeName(OtherScope) orelse @compileError(std.fmt.comptimePrint("Scope at index {} does not have a name", .{j}));

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
        pub const DIContainer = options.di;

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

        pub fn compileRouter(allocator: std.mem.Allocator) Router {
            return Router.fromScopes(comptime compileServerCallTable(), allocator);
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

fn getScopeName(comptime TChild: type) ?[]const u8 {
    if (@hasDecl(TChild, "scope_name")) {
        const scope_name = @field(TChild, "scope_name");
        if (@TypeOf(scope_name) == []const u8) {
            return scope_name;
        }
    }

    return null;
}
