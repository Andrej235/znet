const std = @import("std");

const Service = @import("service.zig").Service;
const Scope = @import("scope.zig").Scope;

pub const Container = struct {
    services: []const Service,

    // the scope is a type created perfectly to hold scoped instances, it must **always** be passed by reference
    // all instances are to be initialized to null and then filled when the service is resolved for the first time
    // after the first resolution, the scope will hold the instance and return its pointer for subsequent resolutions
    pub fn resolve(comptime self: *const Container, comptime T: type, scope: anytype) self.ResolveReturnType(T) {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError(std.fmt.comptimePrint("Only single pointer types can be resolved, got '{}'", .{T}));
        }
        const TService = info.pointer.child;

        inline for (self.services) |service| {
            switch (service) {
                ._transient => |tr| {
                    if (tr.type == TService) {
                        return tr.resolve(self, scope);
                    }
                },
                ._scoped => |sc| {
                    if (sc.type == TService) {
                        const TScope = @TypeOf(scope);
                        const scope_info = @typeInfo(TScope);
                        if (scope_info != .pointer) {
                            @compileError(std.fmt.comptimePrint("Scope must be passed by reference: '{}'", .{T}));
                        }

                        return sc.resolve(scope);
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

    pub fn call(comptime self: *const Container, comptime callback: anytype, scope: anytype) FnReturnType(callback) {
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
            var dependency = self.resolve(arg_field.type, scope);
            @field(args, arg_field.name) = if (@typeInfo(@TypeOf(dependency)) == .pointer) dependency else &dependency;
        }

        return @call(.always_inline, callback, args);
    }

    pub const FunctionScope = Scope.Function;
    pub const SliceScope = Scope.Slice;
    pub const walkDependencyGraph = Scope.walkDependencyGraph;

    fn FnReturnType(comptime callback: anytype) type {
        const info = @typeInfo(@TypeOf(callback));
        if (info != .@"fn") {
            @compileError("Callback must be a function");
        }

        return info.@"fn".return_type orelse void;
    }

    pub fn getServiceType(comptime self: *const Container, comptime TService: type) enum {
        transient,
        scoped,
        singleton,
    } {
        comptime {
            const service = self.getService(TService);

            switch (service) {
                ._transient => return .transient,
                ._scoped => return .scoped,
                ._singleton => return .singleton,
            }
        }
    }

    pub fn getService(comptime self: *const Container, comptime TService: type) Service {
        comptime {
            for (self.services) |service| {
                switch (service) {
                    ._transient => |tr| {
                        if (tr.type == TService) {
                            return service;
                        }
                    },
                    ._scoped => |sc| {
                        if (sc.type == TService) {
                            return service;
                        }
                    },
                    ._singleton => |sg| {
                        if (sg.type == TService) {
                            return service;
                        }
                    },
                }
            }

            @compileError(std.fmt.comptimePrint("Type '{}' is not registered in the container", .{TService}));
        }
    }
};
