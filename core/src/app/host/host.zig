const std = @import("std");

const HostOptions = @import("host_options.zig").HostOptions;

const validateScope = @import("../scope/scope.zig").validateScope;
const Router = @import("../router.zig").Router;
const RuntimeScope = @import("../scope/runtime_scope.zig").RuntimeScope;
const AppOptions = @import("../app.zig").AppOptions;
const ResolvedScopeOptions = @import("../scope/resolved_scope_options.zig").ResolvedScopeOptions;

pub const HostName = []const u8;

pub fn Host(comptime name: ?HostName, comptime scopes: anytype, comptime options: HostOptions) type {
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

    return struct {
        pub const host_name: []const u8 = if (name) |n| n else "*"; // fallback hostname is represented as '*'

        pub fn compileRouter(allocator: std.mem.Allocator, comptime app_options: AppOptions) !Router {
            return try Router.fromScopes(comptime compileServerCallTable(app_options), allocator);
        }

        fn compileServerCallTable(comptime app_options: AppOptions) []const RuntimeScope {
            comptime {
                var runtime_scopes: []const RuntimeScope = &[_]RuntimeScope{};

                for (scope_fields) |field| {
                    const Scope = @field(scopes, field.name);
                    const compile_fn = @field(Scope, "compile");
                    runtime_scopes = runtime_scopes ++ compile_fn(ResolvedScopeOptions.fromHostAndAppOptions(options, app_options));
                }

                return runtime_scopes;
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

const HostValidationError = error{
    HostMissingCompileRouterFn,
    HostCompileRouterFnNotFunction,
    HostCompileRouterFnInvalidReturnType,
    HostCompileRouterFnInvalidParameterCount,
    HostCompileRouterFnInvalidParameterType,

    HostMissingHostName,
    InvalidHostNameType,
};

pub fn validateHost(comptime THost: type) !void {
    comptime {
        if (!@hasDecl(THost, "compileRouter")) {
            return HostValidationError.HostMissingCompileRouterFn;
        }

        const compile_fn = @field(THost, "compileRouter");
        const compile_fn_type_info = @typeInfo(@TypeOf(compile_fn));

        if (compile_fn_type_info != .@"fn") {
            return HostValidationError.HostCompileRouterFnNotFunction;
        }

        const return_type_info = @typeInfo(compile_fn_type_info.@"fn".return_type orelse void);
        if (return_type_info != .error_union or return_type_info.error_union.payload != Router) {
            return HostValidationError.HostCompileRouterFnInvalidReturnType;
        }

        if (compile_fn_type_info.@"fn".params.len != 2) {
            return HostValidationError.HostCompileRouterFnInvalidParameterCount;
        }

        if (compile_fn_type_info.@"fn".params[0].type != std.mem.Allocator or compile_fn_type_info.@"fn".params[1].type != AppOptions) {
            return HostValidationError.HostCompileRouterFnInvalidParameterType;
        }

        if (!@hasDecl(THost, "host_name")) {
            return HostValidationError.HostMissingHostName;
        }

        const host_name = @field(THost, "host_name");
        if (@TypeOf(host_name) != []const u8) {
            return HostValidationError.InvalidHostNameType;
        }
    }
}
