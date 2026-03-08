const ParamKind = @import("param_kind.zig").ParamKind;

pub fn Body(comptime T: type) type {
    return struct {
        pub const Kind = ParamKind.body;
        pub const Type = T;

        value: T,
    };
}
