const std = @import("std");

const Service = @import("service.zig").Service;

pub const Container = struct {
    services: []const Service,

    pub fn resolve(comptime self: *const Container, comptime T: type) self.ResolveReturnType(T) {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError(std.fmt.comptimePrint("Only single pointer types can be resolved, got '{}'", .{T}));
        }
        const TService = info.pointer.child;

        inline for (self.services) |service| {
            switch (service) {
                ._transient => |tr| {
                    if (tr.type == TService) {
                        return tr.resolve(self);
                    }
                },
                ._scoped => |sc| {
                    if (sc.type == TService) {
                        return sc.resolve(self);
                    }
                },
                ._singleton => |sg| {
                    if (sg.type == TService) {
                        return sg.resolve(T);
                    }
                },
            }
        }

        @compileError(std.fmt.comptimePrint("Type '{}' is not registered in the container", .{T}));
    }

    fn isTransient(comptime self: *const Container, comptime T: type) bool {
        comptime {
            const info = @typeInfo(T);
            const TService = info.pointer.child;

            for (self.services) |service| {
                if (service == ._transient and service._transient.type == TService) {
                    return true;
                }
            }

            return false;
        }
    }

    fn ResolveReturnType(comptime self: *const Container, comptime T: type) type {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError(std.fmt.comptimePrint("Only single pointer types can be resolved, got '{}'", .{T}));
        }

        if (self.isTransient(T)) {
            return info.pointer.child;
        }

        return T;
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

        // every args has to be a pointer, this is validated while resolving
        var args: TArgsTuple = undefined;
        inline for (arg_tuple_fields) |arg_field| {
            var dependency = self.resolve(arg_field.type);
            @field(args, arg_field.name) = if (@typeInfo(@TypeOf(dependency)) == .pointer) dependency else &dependency;
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
