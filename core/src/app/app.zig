const std = @import("std");

const DIContainer = @import("../dependency_injection/container.zig").Container;
const HostRouter = @import("../router/host_router.zig").HostRouter;
const Router = @import("../router/router.zig").Router;

const validateHost = @import("host/host.zig").validateHost;
const validateScope = @import("scope/scope.zig").validateScope;

const Host = @import("host/host.zig").Host;
const ActionExecutor = @import("options/action_executor.zig").ActionExecutor;
const Protocol = @import("options/protocol.zig").Protocol;
const RuntimeScope = @import("scope/runtime_scope.zig").RuntimeScope;
const ResolvedScopeOptions = @import("scope/resolved_scope_options.zig").ResolvedScopeOptions;

pub const AppOptions = struct {
    default_action_executor: ActionExecutor = .worker_pool,
    default_action_protocol: []const Protocol = &[_]Protocol{.http},
    di: ?DIContainer = null,
};

const ChildType = enum { scope, host };

pub fn App(comptime children: anytype, comptime options: AppOptions) type {
    const children_type_info = @typeInfo(@TypeOf(children));
    if (children_type_info != .@"struct" or !children_type_info.@"struct".is_tuple) {
        @compileError("App children must be a tuple containing host or scope definitions");
    }

    // children validation
    const children_fields = children_type_info.@"struct".fields;
    if (children_fields.len == 0) {
        @compileError("App must have at least one host or scope defined");
    }

    const TFirstChild = @field(children, children_fields[0].name);
    const first_child_type = validateChild(TFirstChild, 0);

    for (children_fields[1..], 1..) |field, i| {
        const TChild = @field(children, field.name);

        const child_type = validateChild(TChild, i);
        if (child_type != first_child_type) {
            @compileError(std.fmt.comptimePrint("App child at index {} is a different type than the first child (index 0), all children must be either scopes or hosts", .{i}));
        }

        const name: []const u8 = @field(TChild, if (child_type == .host) "host_name" else "scope_name");

        for (children_fields[i + 1 ..], i + 1..) |other_field, j| {
            const TOtherChild = @field(children, other_field.name);
            const other_name: []const u8 = @field(TOtherChild, if (child_type == .host) "host_name" else "scope_name");

            if (std.mem.eql(u8, name, other_name)) {
                @compileError(std.fmt.comptimePrint("App children at index {} and {} have the same name '{s}'", .{ i, j, name }));
            }
        }
    }

    // if the consumer doesn't provide hosts wrap the scopes inside a fallback host in order to match all requests regardless of the host header
    const hosts = if (first_child_type == .host) children else .{Host(null, children, .{})};

    return struct {
        pub const DIContainer = options.di;

        /// Deprecated
        pub fn compileServerCallTable() []const RuntimeScope { // todo: Remove
            return &[_]RuntimeScope{};
        }

        pub fn compileRouter(allocator: std.mem.Allocator) !HostRouter {
            return try HostRouter.fromHosts(hosts, options, allocator);
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

fn getHostName(comptime TChild: type) ?[]const u8 {
    if (@hasDecl(TChild, "host_name")) {
        const host_name = @field(TChild, "host_name");
        if (@TypeOf(host_name) == []const u8) {
            return host_name;
        }
    }

    return null;
}

fn validateChild(comptime TChild: type, comptime index: usize) ChildType {
    validateHost(TChild) catch |host_err| { // not a host
        validateScope(TChild) catch |scope_err| { // not a scope
            @compileError(std.fmt.comptimePrint("App child at index {} is not a scope ({s}) nor a host ({s})", .{ index, @errorName(scope_err), @errorName(host_err) }));
        };

        return .scope;
    };

    return .host;
}
