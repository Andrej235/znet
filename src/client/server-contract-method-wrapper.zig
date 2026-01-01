const std = @import("std");
const Promise = @import("../promise/promise.zig").Promise;

pub fn WrapContractMethodType(comptime TClient: type, comptime method: anytype) type {
    const type_info = @typeInfo(@TypeOf(method));
    const fn_info = switch (type_info) {
        .@"fn" => |@"fn"| @"fn",
        .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            .@"fn" => |fn_info| fn_info,
            else => @compileError("WrapContractMethodType only supports function types"),
        },
        else => @compileError("WrapContractMethodType only supports function types"),
    };

    const ReturnType = *Promise(fn_info.return_type orelse void);

    var arg_fields: [fn_info.params.len]std.builtin.Type.StructField = undefined;
    inline for (fn_info.params, 0..) |param, idx| {
        arg_fields[idx] = std.builtin.Type.StructField{
            .name = std.fmt.comptimePrint("{}", .{idx}),
            .type = param.type.?,
            .alignment = @alignOf(param.type.?),
            .is_comptime = false,
            .default_value_ptr = null,
        };
    }

    const argument = @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .backing_integer = null,
            .layout = .auto,
            .decls = &.{},
            .fields = &arg_fields,
        },
    });

    return *const fn (client: *TClient, args: argument) anyerror!ReturnType;
}

pub fn wrapContractMethod(comptime TClient: type, comptime method: anytype, comptime contract_id: u16, comptime method_id: u16) WrapContractMethodType(TClient, method) {
    const new_fn_info = @typeInfo(@typeInfo(WrapContractMethodType(TClient, method)).pointer.child).@"fn";

    return struct {
        fn invoke(client: *TClient, args: new_fn_info.params[1].type.?) new_fn_info.return_type.? {
            return try client.call(contract_id, method_id, args); // todo: handle expected errors to clean up the returned error union
        }
    }.invoke;
}
