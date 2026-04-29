const std = @import("std");

const DIContainer = @import("../../dependency_injection/container.zig").Container;
const Logger = @import("../../logger/logger.zig").Logger.scoped(.action_handler);

const RequestReader = @import("../../readers/request_body_reader.zig").RequestBodyReader;
const RequestContext = @import("../../requests/request_context.zig").RequestContext;
const ParamKind = @import("../params/param_kind.zig").ParamKind;

const Deserializer = @import("../../serialization/deserializer.zig");
const Serializer = @import("../../serialization/serializer.zig");

const DataValidationError = @import("../../server/validation_errors/data_validation_error.zig").DataValidationError;
const DataValidationErrorResponse = @import("../../server/validation_errors/data_validation_error.zig").DataValidationErrorResponse;

pub fn ActionHandlerArgs(comptime TFn: type, comptime path: []const u8, comptime di: ?DIContainer) type {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    const TReturnType = union(enum) {
        success: ParamsType(TFn),
        failure: DataValidationErrorResponse,
    };

    const max_errors = comptime @min(16, countMaxErrors(TFn));

    return struct {
        pub const Errors = if (max_errors > 0) DataValidationError(max_errors) else void;
        pub const ErrorsResult = DataValidationErrorResponse;

        pub fn getArgs(allocator: std.mem.Allocator, context: *const RequestContext, validation_errors: *Errors) TReturnType {
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
            if (params_info.TBody) |TBody| body_blk: {
                if (context.body) |body| {
                    var reader = RequestReader.init();
                    reader.initInterface(body, context.chunked_body);

                    const deserialization_result = Deserializer.fromContentType(TBody, context.body_content_type, allocator, reader.interface);
                    const payload = deserialization_result catch {
                        const success = validation_errors.add(.body, null, "Failed to deserialize request body");

                        if (!success) {
                            return .{ .failure = validation_errors.toResponseBody() };
                        } else {
                            break :body_blk;
                        }
                    };

                    if (params_info.body_field_name) |name| {
                        @field(params, name) = .{ .value = payload };
                    }
                } else {
                    const success = validation_errors.add(.body, null, "Missing request body");

                    if (!success) {
                        return .{ .failure = validation_errors.toResponseBody() };
                    }
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
                    const current = it.next() orelse switch (validation_errors.add(.path, field.name, "Expected path parameter not found in request")) {
                        true => null,
                        false => return .{ .failure = validation_errors.toResponseBody() },
                    };

                    if (current) |param| {
                        const value = parsePathParam(field.type, param.value) catch |err| blk: {
                            const success = switch (err) {
                                error.FailedToParseNumber => validation_errors.add(.path, field.name, "Expected a valid number"),
                                error.InvalidBooleanValue => validation_errors.add(.path, field.name, "Expected 'true' or 'false' for boolean path parameter"),
                                error.InvalidEnumValue => validation_errors.add(.path, field.name, "Invalid value for enum path parameter"),
                            };

                            if (!success) {
                                return .{ .failure = validation_errors.toResponseBody() };
                            }

                            break :blk null;
                        };

                        if (value) |v| {
                            @field(path_param, field.name) = v;
                        }
                    }
                }

                @field(params, path_field_name) = .{ .value = path_param };
            }

            // Inject and deserialize query parameters if needed
            if (params_info.query_field_name) |query_field_name| {
                var query_reader = std.io.Reader.fixed(if (context.query) |q| q else "");
                const query_params = deserializeQueryParams(allocator, &query_reader, validation_errors, params_info.TQuery.?) catch null;

                // no need for early return in case the errors were truncated because this is the last step of validation

                if (query_params) |q| {
                    @field(params, query_field_name) = .{ .value = q };
                }
            }

            if (comptime Errors != void) {
                if (validation_errors.errors_count > 0) {
                    return .{ .failure = validation_errors.toResponseBody() };
                }
            }

            return .{ .success = params };
        }

        pub fn initErrors() Errors {
            if (comptime Errors == void)
                return {};

            return Errors.init("Failed to parse request parameters");
        }

        fn deserializeQueryParams(allocator: std.mem.Allocator, reader: *std.Io.Reader, errors: *Errors, comptime T: type) !T {
            const info = @typeInfo(T);
            if (info != .@"struct") {
                @compileError("FormUrlEncodedDeserializer can only deserialize into structs");
            }

            var valid = true;
            var result: T = undefined;
            const fields = info.@"struct".fields;

            inline for (fields) |field| {
                comptime if (@typeInfo(field.type) != .optional) continue;

                // initialize all optionals to null in case they are not present in the input
                // this prevents undefined behavior from uninitialized memory
                @field(result, field.name) = null;
            }
            var seen = [_]bool{false} ** fields.len;

            while (reader.takeDelimiter('&') catch |err| blk: {
                Logger.err("Failed to read key-value pair: {}", .{err});
                break :blk null;
            }) |kv| {
                const eq_index = std.mem.indexOfScalar(u8, kv, '=');
                const key = if (eq_index) |i| kv[0..i] else kv;
                const value = if (eq_index) |i| kv[i + 1 ..] else &[_]u8{};

                inline for (fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, key)) {
                        const deserialized_value = Deserializer.FormUrlEncoded.deserializeValue(allocator, value, field.type) catch |err| blk: {
                            const success = switch (err) {
                                Deserializer.DeserializerErrors.IntegerDeserializationFailed, Deserializer.DeserializerErrors.FloatDeserializationFailed => errors.add(.query, field.name, "Expected a valid number"),
                                else => errors.add(.query, field.name, "Invalid value for query parameter"),
                            };

                            if (!success) {
                                return error.InvalidQueryParameters;
                            }

                            valid = false;
                            break :blk null;
                        };

                        if (deserialized_value) |v|
                            @field(result, field.name) = v;

                        seen[i] = true;
                        break;
                    }
                }
            }

            inline for (seen, 0..) |s, i| {
                comptime if (@typeInfo(fields[i].type) == .optional) continue;

                if (!s) {
                    const success = errors.add(.query, fields[i].name, "Missing required query parameter");
                    if (!success) {
                        valid = false;
                        return Deserializer.Errors.MissingRequiredField;
                    }
                }
            }

            if (!valid)
                return error.InvalidQueryParameters;

            return result;
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

fn countMaxErrors(comptime TFn: type) usize {
    comptime {
        var count: usize = 0;
        const fn_info = @typeInfo(TFn).@"fn";

        for (fn_info.params) |param| {
            if (param.type) |TParam| {
                if (@typeInfo(TParam) == .@"struct" and @hasDecl(TParam, "param_kind") and @hasDecl(TParam, "Type")) {
                    const param_kind: ParamKind = @field(TParam, "param_kind");
                    const TInner: type = @field(TParam, "Type");

                    count += switch (param_kind) {
                        .body => 1,
                        .path => @typeInfo(TInner).@"struct".fields.len,
                        .query => @typeInfo(TInner).@"struct".fields.len,
                    };
                }
            }
        }

        return count;
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

const ParsePathParamError = error{
    FailedToParseNumber,
    InvalidBooleanValue,
    InvalidEnumValue,
};

inline fn parsePathParam(comptime T: type, value: []const u8) ParsePathParamError!T {
    const info = @typeInfo(T);

    if (T == []const u8) {
        return value;
    }

    switch (info) {
        .int => {
            return std.fmt.parseInt(T, value, 10) catch
                return error.FailedToParseNumber;
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch
                return error.FailedToParseNumber;
        },
        .bool => {
            if (std.mem.eql(u8, value, "true")) {
                return true;
            } else if (std.mem.eql(u8, value, "false")) {
                return false;
            } else {
                return error.InvalidBooleanValue;
            }
        },
        .@"enum" => |enum_info| {
            inline for (enum_info.fields) |field| {
                if (std.mem.eql(u8, field.name, value)) {
                    return @field(T, field.name);
                }
            }

            return error.InvalidEnumValue;
        },
        else => @compileError(std.fmt.comptimePrint("Unsupported path parameter type: {s}", .{@typeName(T)})),
    }
}
