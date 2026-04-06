const std = @import("std");
const RuntimeScope = @import("scope/runtime_scope.zig").RuntimeScope;
const RuntimeAction = @import("action/runtime_action.zig").RuntimeAction;

const HttpMethod = @import("../server/requests/http.zig").HttpMethod;

pub const Router = struct {
    pub const Node = struct {
        segment: []const u8,
        is_param: bool,
        children: std.ArrayList(Node),
        actions: [HttpMethod.count]?RuntimeAction, // each index corresponds to an HTTP method, null if no action for that method
    };

    nodes: []const Node,

    pub fn fromScopes(scopes: []const RuntimeScope, allocator: std.mem.Allocator) Router {
        var root = Node{
            .segment = "/",
            .is_param = false,
            .children = std.ArrayList(Node){},
            .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
        };

        for (scopes) |scope| {
            for (scope) |action| {
                var segments = std.mem.splitScalar(u8, action.path, '/');
                var current = &root;

                while (segments.next()) |segment| {
                    var found = false;

                    for (current.children.items) |*node| {
                        if (std.mem.eql(u8, node.segment, segment)) {
                            current = @constCast(node);
                            found = true;
                            break;
                        }
                    }

                    if (!found) {
                        // Add segment
                        const new_node = Node{
                            .segment = segment,
                            .is_param = segment.len > 0 and segment[0] == '{',
                            .children = std.ArrayList(Node){},
                            .actions = [_]?RuntimeAction{null} ** HttpMethod.count,
                        };
                        current.children.append(allocator, new_node) catch {};
                        current = @constCast(&current.children.items[current.children.items.len - 1]);
                    }
                }

                const method_idx = @intFromEnum(action.http_method);
                std.debug.assert(current.actions[method_idx] == null);

                current.actions[method_idx] = action;
            }
        }

        return Router{
            .nodes = root.children.items,
        };
    }
};
