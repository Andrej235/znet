const std = @import("std");
const http = @import("../http/http.zig");

const Router = @import("router.zig").Router;
const AppOptions = @import("./app.zig").AppOptions;
const validateHost = @import("host/host.zig").validateHost;

pub const HostRouter = struct {
    pub const Node = struct {
        host_name: []const u8, // empty string for default / fallback host
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

            if (fallback_host_idx) |fallback| {
                if (i == fallback) {
                    host_router.fallback = Node{
                        .host_name = name,
                        .router = router,
                    };
                } else {
                    nodes[i - (if (i > fallback) 1 else 0)] = Node{
                        .host_name = name,
                        .router = router,
                    };
                }
            } else {
                nodes[i] = Node{
                    .host_name = name,
                    .router = router,
                };
            }
        }

        return host_router;
    }

    // todo: return an error set instead of null, error set should have 2 errors one for host not found and one for path not found, return 400 on host not found and 404 on path not found

    // todo: implement wildcards in host names, e.g. *.example.com, and make host router match them correctly
    // prioritize exact matches over wildcard matches, and more specific wildcard matches over less specific ones (e.g. a*.example.com should be prioritized over *.example.com for a host named api.example.com)`

    // todo: support ports
    // todo: support ip hosts, both ipv4 and ipv6
    // todo: validate host structure, e.g. example..com is invalid

    pub const LookupError = error{
        HostNotFound,
        PathNotFound,
    };

    pub fn lookup(self: *const HostRouter, host: []const u8, path: []const u8, method: http.Method) LookupError!Router.Match {
        const normalized_host = normalize(host);

        for (self.hosts) |host_node| {
            if (std.ascii.eqlIgnoreCase(normalized_host, host_node.host_name)) {
                return host_node.router.lookup(path, method) orelse return LookupError.PathNotFound;
            }
        }

        if (self.fallback) |fallback| {
            return fallback.router.lookup(path, method) orelse return LookupError.PathNotFound;
        }

        return LookupError.HostNotFound;
    }

    fn normalize(host: []const u8) []const u8 {
        var normalized = host;

        // remove trailing dots
        normalized = std.mem.trimEnd(u8, host, ".");

        return normalized;
    }
};
