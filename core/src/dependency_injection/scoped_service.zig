const ServiceInitType = @import("service_init_type.zig").ServiceInitType;
const DIContainer = @import("container.zig").Container;

pub const ScopedService = struct {
    type: type,
    init_type: ServiceInitType = .init_fn,

    pub fn resolve(comptime self: ScopedService, comptime container: *const DIContainer) self.type {
        _ = container;
        @compileError("Not implemented");
    }
};
