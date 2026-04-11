const std = @import("std");

const DIContainer = @import("../../dependency_injection/container.zig").Container;
const Logger = @import("../../logger/logger.zig").Logger.scoped(.action_handler);

const RequestContext = @import("./action_handler.zig").RequestContext;
const ParamKind = @import("../params/param_kind.zig").ParamKind;

const Deserializer = @import("../../serialization/deserializer.zig");
const Serializer = @import("../../serialization/serializer.zig");

pub fn ActionHandlerArgs(comptime TFn: type, comptime path: []const u8, comptime di: ?DIContainer) type {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    return struct {
        pub fn getArgs(allocator: std.mem.Allocator, context: RequestContext) !ParamsType(TFn) {
            const params_info = comptime getParamsInfo(TFn);
            const param_fields = params_info.fields;

            const TParams: type = @Type(.{
                .@"struct" = .{
                    .backing_integer = null,
                    .decls = &.{},
                    .fields = param_fields,
                    .layout = .auto,
                    .is_tuple = true,
                },
            });

            const TScope: ?type = comptime blk: {
                if (di == null) {
                    break :blk null;
                }

                var services: []const type = &[_]type{};

                for (param_fields) |field| {
                    const T = field.type;
                    const info = @typeInfo(T);

                    if (info == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type"))
                        continue;

                    const TParam = if (info == .pointer) info.pointer.child else T;
                    services = services ++ &[_]type{TParam};
                }

                break :blk di.?.SliceScope(services);
            };

            // Inject services using DI container if available, otherwise fail at compile time if there are any parameters that cannot be resolved
            var scope: if (TScope) |TS| TS else void = if (TScope) |TS| TS.init() else {};
            var params: TParams = undefined;

            inline for (param_fields) |field| {
                const T = field.type;

                comptime if (T == std.mem.Allocator)
                    continue;

                comptime if (@typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type"))
                    continue;

                // inject
                if (di) |d| {
                    var dependency = d.resolve(field.type, &scope);
                    @field(params, field.name) = if (@typeInfo(@TypeOf(dependency)) == .pointer) dependency else &dependency;
                } else {
                    @compileError(std.fmt.comptimePrint("Cannot resolve parameter of type '{s}' because no DI container is available", .{@typeName(field.type)}));
                }
            }

            // Inject allocator
            if (params_info.allocator_field_name) |field_name| {
                @field(params, field_name) = allocator;
            }

            // Inject and deserialize body if needed
            if (params_info.TBody) |TBody| {
                if (context.body) |body| {
                    var reader: std.io.Reader = .fixed(body);
                    const payload = try Deserializer.fromContentType(TBody, context.body_content_type, allocator, &reader);

                    if (params_info.body_field_name) |name| {
                        @field(params, name) = .{ .value = payload };
                    }
                } else {
                    return error.MissingRequestBody;
                }
            }

            // Extract path parameters from the path and inject them
            // They need to be extracted in the order they appear in the path
            const sorted_path_param_fields: []const std.builtin.Type.StructField = comptime blk: {
                if (params_info.TPath == null) {
                    break :blk &[_]std.builtin.Type.StructField{};
                }

                const path_param_fields = @typeInfo(params_info.TPath.?).@"struct".fields;
                var i = 0;
                var sorted: [path_param_fields.len]std.builtin.Type.StructField = undefined;

                var path_segments = std.mem.splitScalar(u8, path, '/');
                while (path_segments.next()) |segment| {
                    if (segment.len == 0 or segment[0] != '{' or segment[segment.len - 1] != '}') continue;

                    const param_name = segment[1 .. segment.len - 1];
                    for (path_param_fields) |field| {
                        if (std.mem.eql(u8, field.name, param_name)) {
                            sorted[i] = field;
                            i += 1;
                            break;
                        }
                    }
                }

                break :blk &sorted;
            };

            if (params_info.path_field_name) |path_field_name| {
                var path_param: params_info.TPath.? = undefined;

                var it = context.param_iterator;
                inline for (sorted_path_param_fields) |field| {
                    const param = it.next() orelse {
                        Logger.err("Expected path parameter '{s}' not found in request", .{field.name});
                        return error.InvalidPathParameter;
                    };

                    @field(path_param, field.name) = try parsePathParam(field.type, param.value);
                }

                @field(params, path_field_name) = .{ .value = path_param };
            }

            // Inject and deserialize query parameters if needed
            if (params_info.query_field_name) |query_field_name| {
                if (context.query) |query| {
                    var query_reader = std.io.Reader.fixed(query);
                    @field(params, query_field_name) = .{
                        .value = try Deserializer.FormUrlEncoded.deserialize(allocator, &query_reader, params_info.TQuery.?),
                    };
                } else {
                    const empty_query: []const u8 = "";
                    var query_reader = std.io.Reader.fixed(empty_query);
                    @field(params, query_field_name) = .{
                        .value = try Deserializer.FormUrlEncoded.deserialize(allocator, &query_reader, params_info.TQuery.?),
                    };
                }
            }

            return params;
        }
    };
}

fn getParamsInfo(comptime TFn: type) struct {
    fields: []const std.builtin.Type.StructField,

    TBody: ?type,
    body_field_name: ?[]const u8,

    TPath: ?type,
    path_field_name: ?[]const u8,

    TQuery: ?type,
    query_field_name: ?[]const u8,

    allocator_field_name: ?[]const u8,
} {
    comptime {
        const fn_info = @typeInfo(TFn).@"fn";
        var param_fields: [fn_info.params.len]std.builtin.Type.StructField = undefined;

        var TPayload: ?type = null;
        var payload_field_name: ?[]const u8 = null;

        var TPath: ?type = null;
        var path_field_name: ?[]const u8 = null;

        var TQuery: ?type = null;
        var query_field_name: ?[]const u8 = null;

        var allocator_field_name: ?[]const u8 = null;

        for (fn_info.params, 0..) |param, idx| {
            if (param.type) |T| {
                const field_name = std.fmt.comptimePrint("{}", .{idx});

                param_fields[idx] = .{
                    .name = field_name,
                    .type = T,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                };

                if (@typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type")) {
                    const param_kind: ParamKind = @field(T, "param_kind");

                    switch (param_kind) {
                        .body => {
                            TPayload = @field(T, "Type");
                            payload_field_name = field_name;
                        },
                        .path => {
                            TPath = @field(T, "Type");
                            path_field_name = field_name;
                        },
                        .query => {
                            TQuery = @field(T, "Type");
                            query_field_name = field_name;
                        },
                    }
                } else if (T == std.mem.Allocator) {
                    allocator_field_name = field_name;
                }
            }
        }

        return .{
            .fields = param_fields[0..fn_info.params.len],

            .TBody = TPayload,
            .body_field_name = payload_field_name,

            .TPath = TPath,
            .path_field_name = path_field_name,

            .TQuery = TQuery,
            .query_field_name = query_field_name,

            .allocator_field_name = allocator_field_name,
        };
    }
}

fn ParamsType(comptime TFn: type) type {
    const fn_info = @typeInfo(TFn).@"fn";
    var param_fields: [fn_info.params.len]std.builtin.Type.StructField = undefined;

    for (fn_info.params, 0..) |param, idx| {
        const field_name = std.fmt.comptimePrint("{}", .{idx});

        const T = param.type orelse void;
        param_fields[idx] = .{
            .name = field_name,
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .backing_integer = null,
            .decls = &.{},
            .fields = &param_fields,
            .layout = .auto,
            .is_tuple = true,
        },
    });
}

inline fn parsePathParam(comptime T: type, value: []const u8) !T {
    const info = @typeInfo(T);

    if (T == []const u8) {
        return value;
    }

    switch (info) {
        .int => {
            return std.fmt.parseInt(T, value, 10) catch
                return error.InvalidPathParameter;
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch
                return error.InvalidPathParameter;
        },
        .bool => {
            if (std.mem.eql(u8, value, "true")) {
                return true;
            } else if (std.mem.eql(u8, value, "false")) {
                return false;
            } else {
                return error.InvalidPathParameter;
            }
        },
        .@"enum" => |enum_info| {
            inline for (enum_info.fields) |field| {
                if (std.mem.eql(u8, field.name, value)) {
                    return @field(T, field.name);
                }
            }

            return error.InvalidPathParameter;
        },
        else => @compileError(std.fmt.comptimePrint("Unsupported path parameter type: {s}", .{@typeName(T)})),
    }
}
