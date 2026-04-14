const std = @import("std");
const http = @import("../http/http.zig");

const Router = @import("router.zig").Router;
const AppOptions = @import("./app.zig").AppOptions;
const validateHost = @import("host/host.zig").validateHost;
const ParsedHost = @import("host/parsed_host.zig").ParsedHost;

pub const HostRouter = struct {
    pub const Node = struct {
        host: ParsedHost, // empty hostname for fallback / default host
        router: Router,
    };

    fallback: ?Node,
    hosts: []Node,

    pub fn fromHosts(comptime hosts: anytype, comptime app_options: AppOptions, allocator: std.mem.Allocator) !HostRouter {
        const hosts_type_info = @typeInfo(@TypeOf(hosts));
        comptime if (hosts_type_info != .@"struct" or !hosts_type_info.@"struct".is_tuple) {
            @compileError("Host router can only be initialized with a tuple containing host definitions");
        };

        const children_fields = hosts_type_info.@"struct".fields;
        const fallback_host_idx: ?usize = comptime blk: {
            for (children_fields, 0..) |child, i| {
                const TChild = @field(hosts, child.name);
                validateHost(TChild) catch |err| {
                    @compileError(std.fmt.comptimePrint("Host router child '{s}' is not a valid host: {s}", .{ child.name, @errorName(err) }));
                };

                if (@field(TChild, "host_name").len == 0) {
                    break :blk i;
                }
            }

            break :blk null;
        };

        const nodes_count = comptime if (fallback_host_idx) |_| children_fields.len - 1 else children_fields.len;
        var nodes = try allocator.alloc(Node, nodes_count);
        var host_router = HostRouter{
            .fallback = null,
            .hosts = nodes,
        };

        inline for (children_fields, 0..) |child, i| {
            const TChild = @field(hosts, child.name);
            const name: []const u8 = @field(TChild, "host_name");
            const router: Router = try TChild.compileRouter(allocator, app_options);
            const host = comptime if (name.len == 0) ParsedHost{
                .hostname = "",
                .port = null,
                .type = .domain,
            } else ParsedHost.fromHostStr(name) catch @compileError(std.fmt.comptimePrint("Invalid hostname {s}", .{name}));

            if (fallback_host_idx) |fallback| {
                if (i == fallback) {
                    host_router.fallback = Node{
                        .host = host,
                        .router = router,
                    };
                } else {
                    nodes[i - (if (i > fallback) 1 else 0)] = Node{
                        .host = host,
                        .router = router,
                    };
                }
            } else {
                nodes[i] = Node{
                    .host = host,
                    .router = router,
                };
            }
        }

        return host_router;
    }

    // todo: implement wildcards in host names, e.g. *.example.com, and make host router match them correctly
    // prioritize exact matches over wildcard matches, and more specific wildcard matches over less specific ones (e.g. a*.example.com should be prioritized over *.example.com for a host named api.example.com)`

    pub const LookupError = error{
        HostNotFound,
        PathNotFound,
    };

    pub fn lookup(self: *const HostRouter, host: *const ParsedHost, path: []const u8, method: http.Method) LookupError!Router.Match {
        for (self.hosts) |host_node| {
            if (host.equal(&host_node.host)) {
                return host_node.router.lookup(path, method) orelse return LookupError.PathNotFound;
            }
        }

        if (self.fallback) |fallback| {
            return fallback.router.lookup(path, method) orelse return LookupError.PathNotFound;
        }

        return LookupError.HostNotFound;
    }

    pub fn print(self: *const HostRouter) void {
        for (self.hosts) |host_node| {
            std.debug.print("{s}\n", .{host_node.host});
            host_node.router.print(1);
            std.debug.print("\n", .{});
        }

        if (self.fallback) |fallback| {
            std.debug.print("Fallback Host\n", .{});
            fallback.router.print(1);
            std.debug.print("\n", .{});
        }
    }
};
