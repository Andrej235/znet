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

    pub const Match = struct {
        action: RuntimeAction,
        params: ParamIterator,
        query: ?[]const u8,
    };

    pub const ParamIterator = struct {
        request_path: []const u8,
        request_template_path: []const u8,

        request_path_index: usize,
        request_template_path_index: usize,

        pub fn next(self: *ParamIterator) ?struct { name: []const u8, value: []const u8 } {
            while (true) {
                self.request_template_path_index = (std.mem.indexOfScalarPos(u8, self.request_template_path, self.request_template_path_index, '/') orelse return null) + 1;
                self.request_path_index = (std.mem.indexOfScalarPos(u8, self.request_path, self.request_path_index, '/') orelse return null) + 1;

                if (self.request_template_path[self.request_template_path_index] != '{') // not a param segment
                    continue;

                const request_template_path_end_index = std.mem.indexOfScalarPos(u8, self.request_template_path, self.request_template_path_index, '/') orelse self.request_template_path.len;
                const request_path_end_index = std.mem.indexOfScalarPos(u8, self.request_path, self.request_path_index, '/') orelse self.request_path.len;

                const param_name = self.request_template_path[self.request_template_path_index + 1 .. request_template_path_end_index - 1]; // remove { and }
                const param_value = self.request_path[self.request_path_index..request_path_end_index];

                self.request_template_path_index = request_template_path_end_index;
                self.request_path_index = request_path_end_index;

                return .{
                    .name = param_name,
                    .value = param_value,
                };
            }

            return null;
        }
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

    pub fn lookup(self: *const Router, path: []const u8, method: HttpMethod) ?Match {
        const query_index = std.mem.indexOfScalar(u8, path, '?');
        const query = if (query_index) |i| path[i + 1 ..] else null;

        const path_without_query = if (query_index) |i| path[0..i] else path;
        const normalized_path = normalizePath(path_without_query);

        for (self.nodes) |*node| {
            if (lookupNode(node, normalized_path, query, method)) |match| {
                return match;
            }
        }

        return null;
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

fn hasActions(node: *const Router.Node) bool {
    for (node.actions) |action| {
        if (action) |_| {
            return true;
        }
    }
    return false;
}

fn lookupNode(node: *const Router.Node, path: []const u8, query: ?[]const u8, method: HttpMethod) ?Router.Match {
    if (path.len == 0) {
        // root path
        const method_idx = @intFromEnum(method);
        if (node.actions[method_idx]) |action| {
            return Router.Match{
                .action = action,
                .params = .{
                    .request_path = "",
                    .request_template_path = "",
                    .request_path_index = 0,
                    .request_template_path_index = 0,
                },
                .query = null,
            };
        }
        return null;
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

    const method_idx = @intFromEnum(method);
    if (current.actions[method_idx]) |action| {
        return Router.Match{
            .action = action,
            .params = .{
                .request_path = path,
                .request_template_path = normalizePath(action.path),
                .request_path_index = 0,
                .request_template_path_index = 0,
            },
            .query = query,
        };
    }

    return null;
}

fn normalizePath(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}
