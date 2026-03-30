const TransientService = @import("transient_service.zig").TransientService;
const ScopedService = @import("scoped_service.zig").ScopedService;
const SingletonService = @import("singleton_service.zig").SingletonService;

pub const Service = union(enum) {
    _transient: TransientService,
    _scoped: ScopedService,
    _singleton: SingletonService,

    pub fn transient(T: type) Service {
        return .{
            ._transient = .{
                .type = T,
                .init_type = .init_fn,
            },
        };
    }

    pub fn scoped(T: type) Service {
        return .{
            ._scoped = .{
                .type = T,
                .init_type = .init_fn,
            },
        };
    }

    pub fn singleton(ptr: anytype) Service {
        const T = @TypeOf(ptr);
        const info = @typeInfo(T);

        if (info != .pointer) {
            @compileError("Singleton service must be a pointer");
        }

        if (info.pointer.size != .one) {
            @compileError("Singleton service must be a pointer to a single instance");
        }

        return .{
            ._singleton = .{
                .type = info.pointer.child,
                .instance_pointer = ptr,
                .is_const = info.pointer.is_const,
            },
        };
    }

    pub fn resolve(comptime self: Service) InnerType(self) {
        return switch (self) {
            ._transient => |tr| tr.resolve(),
            ._scoped => |sc| sc.resolve(),
            ._singleton => |si| si.resolve(),
        };
    }

    fn InnerType(comptime self: Service) type {
        return switch (self) {
            ._transient => |tr| tr.type,
            ._scoped => |sc| sc.type,
            ._singleton => |si| si.type,
        };
    }
};
