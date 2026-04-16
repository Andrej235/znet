const std = @import("std");
const http = @import("../http/http.zig");

const Router = @import("router.zig").Router;
const AppOptions = @import("./app.zig").AppOptions;
const validateHost = @import("host/host.zig").validateHost;
const RequestHost = @import("host/request_host.zig").RequestHost;
const PatternHost = @import("host/host_pattern.zig").HostPattern;

pub const HostRouter = struct {
    pub const Node = struct {
        host: PatternHost, // fallback has hostname set to '*'
        router: Router,
    };

    /// sorted by host specificity (most specific first), fallback host (if exists) is always last
    hosts: []Node,

    pub fn fromHosts(comptime hosts: anytype, comptime app_options: AppOptions, allocator: std.mem.Allocator) !HostRouter {
        const hosts_type_info = @typeInfo(@TypeOf(hosts));
        comptime if (hosts_type_info != .@"struct" or !hosts_type_info.@"struct".is_tuple) {
            @compileError("Host router can only be initialized with a tuple containing host definitions");
        };

        const children_fields = hosts_type_info.@"struct".fields;
        var nodes = try allocator.alloc(Node, children_fields.len);

        inline for (children_fields, 0..) |child, i| {
            const TChild = @field(hosts, child.name);
            const name: []const u8 = @field(TChild, "host_name");
            const router: Router = try TChild.compileRouter(allocator, app_options);
            const host = PatternHost.fromHostStr(name);

            nodes[i] = Node{
                .host = host,
                .router = router,
            };
        }

        const SpecificityComparator = struct {
            pub fn lessThan(_: void, a: Node, b: Node) bool {
                return @intFromEnum(a.host.specificity) > @intFromEnum(b.host.specificity);
            }
        };
        std.mem.sort(Node, nodes, {}, SpecificityComparator.lessThan);

        return HostRouter{
            .hosts = nodes,
        };
    }

    pub const LookupError = error{
        HostNotFound,
        PathNotFound,
    };

    pub fn lookup(self: *const HostRouter, host: *const RequestHost, path: []const u8, method: http.Method) LookupError!Router.Match {
        for (self.hosts) |host_node| {
            if (host_node.host.match(host)) {
                return host_node.router.lookup(path, method) orelse return LookupError.PathNotFound;
            }
        }

        return LookupError.HostNotFound;
    }

    pub fn print(self: *const HostRouter) void {
        for (self.hosts) |*host_node| {
            switch (host_node.host.hostname) {
                .domain => |parts| {
                    if (parts.len == 1 and parts[0][0] == '*') {
                        std.debug.print("* (fallback)\n", .{});
                    } else {
                        for (parts[0 .. parts.len - 1]) |part| {
                            std.debug.print("{s}.", .{part});
                        }
                        std.debug.print("{s}", .{parts[parts.len - 1]});

                        std.debug.print("\n", .{});
                    }
                },
                .ip_v4 => |ip| {
                    std.debug.print("Host: {}.{}.{}.{}\n", .{ ip[0], ip[1], ip[2], ip[3] });
                },
                .ip_v6 => |ip| {
                    for (ip[0..15]) |part| {
                        std.debug.print("{x}:", .{part});
                    }
                    std.debug.print("{x}", .{ip[15]});
                    std.debug.print("\n", .{});
                },
            }

            host_node.router.print(1);
            std.debug.print("\n", .{});
        }
    }
};
