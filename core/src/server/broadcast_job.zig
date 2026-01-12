const Audience = @import("context/audience.zig").Audience;
const std = @import("std");

pub const BroadcastJob = struct {
    message: []const u8,
    bitset: std.bit_set.DynamicBitSet,
};
