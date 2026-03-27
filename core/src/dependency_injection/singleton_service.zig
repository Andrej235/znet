const std = @import("std");

pub const SingletonService = struct {
    type: type,
    instance_pointer: *const anyopaque,
    is_const: bool,

    pub fn resolve(comptime self: SingletonService, comptime TRequested: type) TRequested {
        const requested_info = @typeInfo(TRequested);
        if (requested_info != .pointer or requested_info.pointer.size != .one) {
            @compileError(std.fmt.comptimePrint("Only single pointer types can be resolved, got '{}'", .{TRequested}));
        }

        if (self.is_const and !requested_info.pointer.is_const) {
            @compileError(std.fmt.comptimePrint("Cannot resolve const singleton as non-const pointer, requested '{s}'", .{@typeName(TRequested)}));
        }

        if (!self.is_const and !requested_info.pointer.is_const)
            return @ptrCast(@alignCast(@constCast(self.instance_pointer)));

        return @ptrCast(@alignCast(self.instance_pointer));
    }
};
