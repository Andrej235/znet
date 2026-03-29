const std = @import("std");

const Container = @import("container.zig").Container;

pub const Scope = struct {
    /// Generates a scope using all dependencies needed to call the provided function, walking the dependency graph to find them
    pub fn Function(comptime container: *const Container, comptime function: anytype) type {
        comptime {
            const T = @TypeOf(function);
            const info = @typeInfo(T);
            if (info != .@"fn") {
                @compileError("FunctionScope can only be created for functions");
            }

            const field_types = walkDependencyGraph(container, T);
            return Internal(container, field_types);
        }
    }

    /// Generates a scope using given services and all their dependencies, walking the dependency graph to find them
    pub fn Slice(comptime container: *const Container, comptime services: []const type) type {
        comptime {
            var alL_services: []const type = services;

            for (services) |service| {
                const service_deps = walkDependencyGraph(container, service);
                for (service_deps) |dep| {
                    if (!std.mem.containsAtLeastScalar(type, alL_services, 1, dep)) {
                        alL_services = alL_services ++ &[_]type{dep};
                    }
                }
            }

            return Internal(container, alL_services);
        }
    }

    /// Generates a scope using given services, **doesn't** walk the dependency graph
    fn Internal(comptime di: *const Container, comptime services: []const type) type {
        comptime {
            if (services.len == 0) {
                return Empty();
            }

            var fields: [services.len]std.builtin.Type.StructField = undefined;

            for (services, 0..) |TDep, i| {
                fields[i] = std.builtin.Type.StructField{
                    .name = std.fmt.comptimePrint("{}", .{i}),
                    .type = ScopedServiceContainer(TDep),
                    .alignment = @alignOf(ScopedServiceContainer(TDep)),
                    .is_comptime = false,
                    .default_value_ptr = null,
                };
            }

            const TContainer = @Type(.{
                .@"struct" = .{
                    .backing_integer = null,
                    .decls = &.{},
                    .fields = &fields,
                    .is_tuple = true,
                    .layout = .auto,
                },
            });

            return struct {
                const Self = @This();

                container: TContainer,

                pub fn resolve(self: *Self, comptime TService: type) *TService {
                    const service_field_name = comptime field_name: {
                        for (services, 0..) |TDep, i| {
                            if (TDep == TService) {
                                break :field_name std.fmt.comptimePrint("{}", .{i});
                            }
                        }

                        @compileError(std.fmt.comptimePrint("Service of type '{}' is not part of this scope and cannot be resolved", .{TService}));
                    };

                    var scoped_service_container: *ScopedServiceContainer(TService) = &@field(self.container, service_field_name);
                    if (scoped_service_container.initialized) {
                        return &scoped_service_container.value;
                    }

                    // create a new instance of the service and store it in the scope for future resolutions
                    const service = di.getService(TService)._scoped;
                    switch (service.init_type) {
                        .construct => return TService{},
                        .init_fn => {
                            const init_fn = @field(TService, "init");
                            const instance = di.call(init_fn, self);
                            @field(self.container, service_field_name) = ScopedServiceContainer(TService){
                                .value = instance,
                                .initialized = true,
                            };

                            return &@field(self.container, service_field_name).value;
                        },
                    }
                }

                pub fn init() Self {
                    var container: TContainer = undefined;

                    inline for (fields) |field| {
                        @field(container, field.name) = field.type{
                            .value = undefined,
                            .initialized = false,
                        };
                    }

                    return Self{
                        .container = container,
                    };
                }
            };
        }
    }

    /// Returns a list of all scoped dependencies needed to resolve a service or call a function of type T, excluding that service itself
    pub fn walkDependencyGraph(comptime container: *const Container, comptime T: type) []const type {
        comptime {
            const info = @typeInfo(T);

            switch (info) {
                .@"struct" => {
                    if (!@hasDecl(T, "init")) {
                        @compileError(std.fmt.comptimePrint("Type '{}' does not have an 'init' function but was registered as a transient service with init type set to init_fn", .{T}));
                    }

                    const init_fn = @field(T, "init");
                    return walkDependencyGraph(container, @TypeOf(init_fn));
                },
                .@"fn" => |fn_info| {
                    const params = fn_info.params;
                    if (params.len == 0) return &.{};

                    var dependencies: []const type = &.{};

                    for (params) |param| {
                        if (param.type == null) continue;

                        const TParam = param.type.?;
                        const param_info = @typeInfo(TParam);
                        if (param_info != .pointer or param_info.pointer.size != .one) {
                            @compileError(std.fmt.comptimePrint("Only single pointer parameters are supported in 'init' functions, but parameter {} of type {} does not meet this requirement", .{ param.name, TParam }));
                        }

                        const TChild = param_info.pointer.child;
                        const service = container.getService(TChild);

                        switch (service) {
                            ._scoped => |sc| {
                                const to_add = if (sc.init_type == .init_fn) &[_]type{TChild} ++ walkDependencyGraph(container, TChild) else &[_]type{TChild};

                                // add nested deps, check for dupes
                                for (to_add) |TDep| {
                                    if (!std.mem.containsAtLeastScalar(type, dependencies, 1, TDep)) {
                                        dependencies = dependencies ++ &[_]type{TDep};
                                    }
                                }
                            },
                            ._transient => |tr| {
                                if (tr.init_type == .init_fn) {
                                    // add nested deps, check for dupes
                                    const nested_deps = walkDependencyGraph(container, TChild);
                                    for (nested_deps) |TDep| {
                                        if (!std.mem.containsAtLeastScalar(type, dependencies, 1, TDep)) {
                                            dependencies = dependencies ++ &[_]type{TDep};
                                        }
                                    }
                                }
                            },
                            ._singleton => continue,
                        }
                    }

                    return dependencies;
                },
                else => @compileError(std.fmt.comptimePrint("Unsupported type '{}' in dependency graph, only structs and functions are supported", .{T})),
            }
        }
    }

    pub fn Empty() type {
        return struct {
            const Self = @This();

            container: void,

            pub fn resolve(_: *Self, comptime TService: type) *TService {
                @compileError(std.fmt.comptimePrint("No dependencies can be resolved in an empty scope, tried to resolve {}", .{TService}));
            }

            pub fn init() Self {
                return Self{
                    .container = {},
                };
            }
        };
    }
};

fn ScopedServiceContainer(comptime T: type) type {
    return struct {
        value: T = undefined,
        initialized: bool = false,
    };
}
