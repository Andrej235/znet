const std = @import("std");

const Protocol = @import("../options/protocol.zig").Protocol;
const ParamKind = @import("../params/param_kind.zig").ParamKind;

/// Validates that the handler function of an action is compatible with the action's protocol and path parameters,
/// and that the path parameters defined in the handler function match the path parameters defined in the action's path.
/// Throws compile errors with detailed messages if any issues are found.
pub fn validateActionParams(comptime handler_fn: anytype, comptime protocol: []const Protocol, absolute_path: []const u8) void {
    comptime {
        if (protocol.len == 0) {
            @compileError("Protocol must be specified for action: " ++ absolute_path);
        }

        const params = extractParams(handler_fn, absolute_path);

        const expected_path_params = parsePathParams(absolute_path);
        if (params.TPath) |TPath| {
            validatePathParams(structFieldNames(TPath, absolute_path), expected_path_params, absolute_path);
        } else if (expected_path_params.len > 0) { // it's missing all params, but just report the first one to avoid overwhelming users with errors
            @compileError(std.fmt.comptimePrint("Action at {s} defines an unused path parameter '{s}'", .{ absolute_path, expected_path_params[0] }));
        }
    }
}

fn extractParams(comptime handler_fn: anytype, comptime path: []const u8) struct {
    TBody: ?type,
    TQuery: ?type,
    TPath: ?type,
} {
    const handler_fn_type_info = @typeInfo(@TypeOf(handler_fn)).@"fn"; // handler_fn must be a function, enforced by Action
    const params = handler_fn_type_info.params;

    var TBody: ?type = null;
    var TQuery: ?type = null;
    var TPath: ?type = null;

    for (params) |param| {
        const T = param.type orelse continue;

        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type")) {
            const param_kind: ParamKind = @field(T, "param_kind");
            const TInnerParam: type = @field(T, "Type");

            switch (param_kind) {
                .body => {
                    if (TBody != null) {
                        @compileError(std.fmt.comptimePrint("Multiple body parameters are not allowed in action handler functions. Try wrapping them in a struct. Found multiple in action at {s}", .{path}));
                    }

                    TBody = TInnerParam;
                },
                .query => {
                    if (TQuery != null) {
                        @compileError(std.fmt.comptimePrint("Multiple query parameters are not allowed in action handler functions. Try wrapping them in a struct. Found multiple in action at {s}", .{path}));
                    }

                    TQuery = TInnerParam;
                },
                .path => {
                    if (TPath != null) {
                        @compileError(std.fmt.comptimePrint("Multiple path parameters are not allowed in action handler functions. Try wrapping them in a struct. Found multiple in action at {s}", .{path}));
                    }

                    TPath = TInnerParam;
                },
            }
        }
    }

    return .{
        .TBody = TBody,
        .TQuery = TQuery,
        .TPath = TPath,
    };
}

fn parsePathParams(comptime path: []const u8) []const []const u8 {
    var res: []const []const u8 = &[_][]const u8{};

    var i: usize = 0;
    var start: ?usize = null;

    while (i < path.len) : (i += 1) {
        switch (path[i]) {
            '{' => {
                if (start != null) invalidPath(path);
                start = i + 1;
            },
            '}' => {
                if (start == null) invalidPath(path);

                const name = path[start.?..i];
                if (name.len == 0) invalidPath(path);

                res = res ++ &[_][]const u8{name};
                start = null;
            },
            '/' => if (start != null) invalidPath(path),
            else => {
                const c = path[i];
                if (start == null) {
                    if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '~') {
                        @compileError(std.fmt.comptimePrint("Invalid character '{s}' in action path: {s}", .{ [_]u8{c}, path }));
                    }
                }
            },
        }
    }

    if (start != null) invalidPath(path);

    return res;
}

fn invalidPath(path: []const u8) noreturn {
    @compileError("Invalid path segment in action path: " ++ path);
}

fn structFieldNames(comptime T: type, path: []const u8) []const []const u8 {
    const info = @typeInfo(T);

    if (info != .@"struct") {
        @compileError(std.fmt.comptimePrint(
            "Path parameter type must be a struct in action at {s}",
            .{path},
        ));
    }

    const fields = info.@"struct".fields;

    var result: []const []const u8 = &[_][]const u8{};
    inline for (fields) |f| {
        result = result ++ &[_][]const u8{f.name};
    }

    return result;
}

fn validatePathParams(comptime found: []const []const u8, comptime expected: []const []const u8, comptime path: []const u8) void {
    // Missing
    inline for (expected) |name| {
        if (!contains(found, name)) {
            @compileError(std.fmt.comptimePrint(
                "Missing path parameter '{s}' in action at {s}",
                .{ name, path },
            ));
        }
    }

    // Extra
    inline for (found) |name| {
        if (!contains(expected, name)) {
            @compileError(std.fmt.comptimePrint(
                "Extra path parameter '{s}' in action at {s}",
                .{ name, path },
            ));
        }
    }
}

fn contains(comptime list: []const []const u8, name: []const u8) bool {
    inline for (list) |item| {
        // avoid hitting the default quota of 1000, since there could be many path params
        @setEvalBranchQuota(1_000_000);
        if (std.mem.eql(u8, item, name)) return true;
        @setEvalBranchQuota(1000);
    }
    return false;
}
