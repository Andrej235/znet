const ParamKind = @import("param_kind.zig").ParamKind;

pub fn Query(comptime T: type) type {
    return struct {
        pub const param_kind = ParamKind.query;
        pub const Type = T;

        value: T,
    };
}
