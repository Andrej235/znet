const ParamKind = @import("param_kind.zig").ParamKind;

pub fn Path(comptime T: type) type {
    return struct {
        pub const param_kind = ParamKind.path;
        pub const Type = T;

        value: T,
    };
}
