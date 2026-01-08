const Audience = @import("context/audience.zig").Audience;

pub const BroadcastJob = struct {
    message: []const u8,
    target_audience: Audience,
};
