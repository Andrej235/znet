const std = @import("std");

const Container = @import("container.zig").Container;

pub const Scope = struct {
    pub fn Function(comptime container: *const Container, comptime function: anytype) type {
        comptime {
            const T = @TypeOf(function);
            const info = @typeInfo(T);
            if (info != .@"fn") {
                @compileError("FunctionScope can only be created for functions");
            }

            const field_types = walkDependencyGraph(container, T);
            if (field_types.len == 0) {
                return Empty();
            }

            var fields: [field_types.len]std.builtin.Type.StructField = undefined;

            for (field_types, 0..) |TDep, i| {
                fields[i] = std.builtin.Type.StructField{
                    .name = @typeName(TDep),
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
                    .is_tuple = false,
                    .layout = .auto,
                },
            });

            return struct {
                const Self = @This();

                container: TContainer,

                pub fn resolve(self: *Self, comptime TService: type) *TService {
                    if (!@hasField(@TypeOf(self.container), @typeName(TService))) {
                        @compileError(std.fmt.comptimePrint("Service '{}' is not a dependency of this scope", .{TService}));
                    }

                    var scoped_service_container: *ScopedServiceContainer(TService) = &@field(self.container, @typeName(TService));
                    if (scoped_service_container.initialized) {
                        return &scoped_service_container.value;
                    }

                    // create a new instance of the service and store it in the scope for future resolutions
                    const service = container.getService(TService)._scoped;
                    switch (service.init_type) {
                        .construct => return TService{},
                        .init_fn => {
                            const init_fn = @field(TService, "init");
                            const instance = container.call(init_fn, self);
                            @field(self.container, @typeName(TService)) = ScopedServiceContainer(TService){
                                .value = instance,
                                .initialized = true,
                            };

                            return &@field(self.container, @typeName(TService)).value;
                        },
                    }
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
                        const paramInfo = @typeInfo(TParam);
                        if (paramInfo != .pointer or paramInfo.pointer.size != .one) {
                            @compileError(std.fmt.comptimePrint("Only single pointer parameters are supported in 'init' functions, but parameter {} of type {} does not meet this requirement", .{ param.name, TParam }));
                        }

                        const TChild = paramInfo.pointer.child;
                        const service = container.getService(TChild);

                        switch (service) {
                            ._scoped => |sc| {
                                dependencies = dependencies ++ &[_]type{TChild};

                                if (sc.init_type == .init_fn) {
                                    // add nested deps, check for dupes
                                    const nestedDeps = walkDependencyGraph(container, TChild);
                                    for (nestedDeps) |TDep| {
                                        if (!std.mem.containsAtLeastScalar(type, dependencies, 1, TDep)) {
                                            dependencies = dependencies ++ &.{TDep};
                                        }
                                    }
                                }
                            },
                            ._transient => |tr| {
                                if (tr.init_type == .init_fn) {
                                    // add nested deps, check for dupes
                                    const nestedDeps = walkDependencyGraph(container, TChild);
                                    for (nestedDeps) |TDep| {
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
            pub fn resolve(comptime T: type) T {
                @compileError(std.fmt.comptimePrint("No dependencies can be resolved in an empty scope, tried to resolve {}", .{T}));
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
