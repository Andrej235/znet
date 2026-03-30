const std = @import("std");

const ServiceInitType = @import("service_init_type.zig").ServiceInitType;
const DIContainer = @import("container.zig").Container;

pub const TransientService = struct {
    type: type,
    init_type: ServiceInitType = .init_fn,

    pub fn resolve(comptime self: TransientService, comptime container: *const DIContainer, scope: anytype) self.type {
        const T = self.type;

        return switch (self.init_type) {
            .init_fn => {
                if (!@hasDecl(T, "init")) {
                    @compileError(std.fmt.comptimePrint("Type '{}' does not have an 'init' function but was registered as a transient service with init type set to init_fn", .{T}));
                }

                const init_fn = @field(T, "init");
                const init_fn_type_info = @typeInfo(@TypeOf(init_fn));

                if (init_fn_type_info != .@"fn") {
                    @compileError(std.fmt.comptimePrint("'init' field of type '{}' is not a function", .{T}));
                }

                if (init_fn_type_info.@"fn".return_type != T) {
                    @compileError(std.fmt.comptimePrint("'init' function of type '{}' does not return the correct type", .{T}));
                }

                return container.call(init_fn, scope);
            },
            .construct => return T{},
        };
    }
};
