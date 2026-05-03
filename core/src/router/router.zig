const std = @import("std");
const RuntimeScope = @import("../app/scope/runtime_scope.zig").RuntimeScope;
const RuntimeAction = @import("../app/action/runtime_action.zig").RuntimeAction;
const ParamIterator = @import("param_iterator.zig").ParamIterator;

const HttpMethod = @import("../http/http.zig").Method;
const MethodsBitmap = @import("route_method_bitmap.zig").RouteMethodBitmap;

pub const Router = struct {
    pub const Node = struct {
        segment: []const u8,
        static_children: std.ArrayList(Node),
        param_child: ?*Node, // only one param child allowed per node
        actions: [HttpMethod.count]?RuntimeAction, // each index corresponds to an HTTP method, null if no action for that method
        has_actions: bool, // optimization to avoid iterating over actions array when printing
        methods_bitmap: MethodsBitmap, // bitmap of allowed methods for this node and its children, used for 405 Method Not Allowed
    };

    pub const Match = struct {
        action: RuntimeAction,
        params: ParamIterator,
        query: ?[]const u8,
    };

    pub const MatchResult = union(enum) {
        match: Match,
        not_found,
        method_not_allowed: MethodsBitmap, // bitmap of allowed methods
    };

    nodes: []const Node,

    pub fn fromScopes(comptime scopes: []const RuntimeScope, allocator: std.mem.Allocator) !Router {
        var root = Node{
            .segment = "/",
            .static_children = std.ArrayList(Node){},
            .param_child = null,
            .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
            .has_actions = false,
            .methods_bitmap = .init(0),
        };

        for (scopes) |scope| {
            for (scope) |action| {
                var current = &root;

                const normalized_path = normalizePath(action.path);
                var segments = std.mem.splitScalar(u8, normalized_path, '/');

                while (segments.next()) |segment| {
                    if (segment.len > 0 and segment[0] == '{') {
                        // param

                        if (current.param_child) |param_child| {
                            if (!std.mem.eql(u8, param_child.segment, segment[1 .. segment.len - 1])) {
                                return error.ConflictingParameterNames;
                            }
                            current = param_child;
                        } else {
                            const new_node = try allocator.create(Node);
                            new_node.* = Node{
                                .segment = segment[1 .. segment.len - 1], // remove { and }
                                .static_children = std.ArrayList(Node){},
                                .param_child = null,
                                .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
                                .has_actions = false,
                                .methods_bitmap = .init(0),
                            };
                            current.param_child = new_node;
                            current = new_node;
                        }
                    } else {
                        // static
                        var found = false;

                        for (current.static_children.items) |*node| {
                            if (std.mem.eql(u8, node.segment, segment)) {
                                current = @constCast(node);
                                found = true;
                                break;
                            }
                        }

                        if (!found) { // add new static node
                            const new_node = Node{
                                .segment = segment,
                                .static_children = std.ArrayList(Node){},
                                .param_child = null,
                                .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
                                .has_actions = false,
                                .methods_bitmap = .init(0),
                            };
                            try current.static_children.append(allocator, new_node);
                            current = @constCast(&current.static_children.items[current.static_children.items.len - 1]);
                        }
                    }
                }

                std.debug.assert(!current.methods_bitmap.hasMethod(action.http_method));

                const http_method_index = @intFromEnum(action.http_method);
                current.actions[http_method_index] = action;
                current.has_actions = true;
                current.methods_bitmap.addMethod(action.http_method);
            }
        }

        return Router{
            .nodes = root.static_children.items,
        };
    }

    pub fn print(self: *const Router, indent: usize) void {
        for (self.nodes) |*node| {
            printWithIndent(node, indent, false);
        }
    }

    pub fn lookup(self: *const Router, path: []const u8, method: HttpMethod) MatchResult {
        const query_index = std.mem.indexOfScalar(u8, path, '?');
        const query = if (query_index) |i| path[i + 1 ..] else null;

        const path_without_query = if (query_index) |i| path[0..i] else path;
        const normalized_path = normalizePath(path_without_query);

        for (self.nodes) |*root| {
            if (lookupNode(root, normalized_path)) |node| {
                const method_idx = @intFromEnum(method);

                if (node.actions[method_idx]) |action| {
                    return .{
                        .match = Match{
                            .action = action,
                            .params = .init(normalizePath(path), normalizePath(action.path)),
                            .query = query,
                        },
                    };
                }

                if (!node.has_actions) {
                    return .not_found;
                }

                return .{
                    .method_not_allowed = node.methods_bitmap,
                };
            }
        }

        return .not_found;
    }
};

fn printWithIndent(node: *const Router.Node, indent: usize, is_param: bool) void {
    const segment = if (node.segment.len > 0) node.segment else "/";
    for (0..indent) |_| {
        std.debug.print("|  ", .{});
    }

    std.debug.print("> ", .{});
    if (is_param) {
        std.debug.print("{{", .{});
        std.debug.print("{s}", .{segment});
        std.debug.print("}}", .{});
    } else {
        std.debug.print("{s}", .{segment});
    }

    if (node.has_actions) {
        std.debug.print(" (", .{});

        var found = false;
        for (node.actions) |action| {
            if (action) |a| {
                if (found) {
                    std.debug.print(", ", .{});
                }
                std.debug.print("{s}", .{@tagName(a.http_method)});
                found = true;
            }
        }

        std.debug.print(")", .{});
    }

    std.debug.print("\n", .{});

    for (node.static_children.items) |*child| {
        printWithIndent(child, indent + 1, false);
    }

    if (node.param_child) |param_child| {
        printWithIndent(param_child, indent + 1, true);
    }
}

fn lookupNode(node: *const Router.Node, path: []const u8) ?*const Router.Node {
    if (path.len == 0) {
        // root path
        return node;
    }

    var segments = std.mem.splitScalar(u8, path, '/');
    const first = segments.first();
    if (!std.mem.eql(u8, node.segment, first)) {
        return null;
    }

    var current = node;

    while (segments.next()) |segment| {
        var found = false;

        for (current.static_children.items) |*child| {
            if (std.mem.eql(u8, child.segment, segment)) {
                current = @constCast(child);
                found = true;
                break;
            }
        }

        if (!found) {
            if (current.param_child) |param_child| {
                current = param_child;
                found = true;
            }
        }

        if (!found) {
            return null;
        }
    }

    return current;
}

fn normalizePath(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}
