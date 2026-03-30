const ParamKind = @import("param_kind.zig").ParamKind;

pub fn Body(comptime T: type) type {
    return struct {
        pub const param_kind = ParamKind.body;
        pub const Type = T;

        value: T,
    };
}
