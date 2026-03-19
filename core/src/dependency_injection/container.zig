const std = @import("std");

const Service = @import("service.zig").Service;

pub const Container = struct {
    services: []const Service,

    pub fn resolve(comptime self: *const Container, comptime T: type) T {
        inline for (self.services) |service| {
            switch (service) {
                ._transient => |tr| {
                    if (tr.type == T) {
                        return tr.resolve(self);
                    }
                },
                ._scoped => |sc| {
                    if (sc.type == T) {
                        return sc.resolve(self);
                    }
                },
                ._singleton => |sg| {
                    if (sg.type == T) {
                        return sg.resolve(self);
                    }
                },
            }
        }

        @compileError(std.fmt.comptimePrint("Type '{}' is not registered in the container", .{T}));
    }

    pub fn call(comptime self: *const Container, comptime callback: anytype) FnReturnType(callback) {
        const info = @typeInfo(@TypeOf(callback));
        if (info != .@"fn") {
            @compileError("Callback must be a function");
        }

        const params = info.@"fn".params;
        const arg_tuple_fields: []const std.builtin.Type.StructField = comptime blk: {
            var fields: [params.len]std.builtin.Type.StructField = undefined;

            for (params, 0..) |param, i| {
                fields[i] = .{
                    .name = std.fmt.comptimePrint("{}", .{i}),
                    .type = param.type orelse @compileError(std.fmt.comptimePrint("Parameter {} does not have a type", .{i})),
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(param.type.?),
                };
            }

            break :blk &fields;
        };

        const TArgsTuple = @Type(.{
            .@"struct" = .{
                .is_tuple = true,
                .decls = &.{},
                .fields = arg_tuple_fields,
                .layout = .auto,
            },
        });

        var args: TArgsTuple = undefined;
        inline for (arg_tuple_fields) |arg_field| {
            @field(args, arg_field.name) = self.resolve(arg_field.type);
        }

        return @call(.always_inline, callback, args);
    }

    fn FnReturnType(comptime callback: anytype) type {
        const info = @typeInfo(@TypeOf(callback));
        if (info != .@"fn") {
            @compileError("Callback must be a function");
        }

        return info.@"fn".return_type orelse void;
    }
};
