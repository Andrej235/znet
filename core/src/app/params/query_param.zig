const ParamKind = @import("param_kind.zig").ParamKind;

pub fn Query(comptime T: type) type {
    return struct {
        pub const Kind = ParamKind.query;
        pub const Type = T;

        value: T,
    };
}
