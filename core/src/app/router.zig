const std = @import("std");
const RuntimeScope = @import("scope/runtime_scope.zig").RuntimeScope;
const RuntimeAction = @import("action/runtime_action.zig").RuntimeAction;

const HttpMethod = @import("../server/requests/http.zig").HttpMethod;

pub const Router = struct {
    pub const Node = struct {
        segment: []const u8,
        static_children: std.ArrayList(Node),
        param_child: ?*Node, // only one param child allowed per node
        actions: [HttpMethod.count]?RuntimeAction, // each index corresponds to an HTTP method, null if no action for that method
    };

    nodes: []const Node,

    pub fn fromScopes(scopes: []const RuntimeScope, allocator: std.mem.Allocator) !Router {
        var root = Node{
            .segment = "/",
            .static_children = std.ArrayList(Node){},
            .param_child = null,
            .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
        };

        for (scopes) |scope| {
            for (scope) |action| {
                var segments = std.mem.splitScalar(u8, action.path, '/');
                var current = &root;

                while (segments.next()) |segment| {
                    var found = false;

                    for (current.static_children.items) |*node| {
                        if (std.mem.eql(u8, node.segment, segment)) {
                            current = @constCast(node);
                            found = true;
                            break;
                        }
                    }

                    if (!found) {
                        if (segment.len > 0 and segment[0] == '{') {
                            // param
                            const new_node = try allocator.create(Node);
                            new_node.* = Node{
                                .segment = segment[1..segment.len - 1], // remove { and }
                                .static_children = std.ArrayList(Node){},
                                .param_child = null,
                                .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
                            };
                            current.param_child = new_node;
                            current = new_node;
                        } else {
                            // static
                            const new_node = Node{
                                .segment = segment,
                                .static_children = std.ArrayList(Node){},
                                .param_child = null,
                                .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
                            };
                            try current.static_children.append(allocator, new_node);
                            current = @constCast(&current.static_children.items[current.static_children.items.len - 1]);
                        }
                    }
                }

                const method_idx = @intFromEnum(action.http_method);
                std.debug.assert(current.actions[method_idx] == null);

                current.actions[method_idx] = action;
            }
        }

        return Router{
            .nodes = root.static_children.items,
        };
    }

    pub fn print(self: *const Router) void {
        for (self.nodes) |*node| {
            printWithIndent(node, 0, false);
        }
    }

    fn printWithIndent(node: *const Node, indent: usize, is_param: bool) void {
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

        if (hasActions(node)) {
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

    fn hasActions(node: *const Node) bool {
        for (node.actions) |action| {
            if (action) |_| {
                return true;
            }
        }
        return false;
    }
};
