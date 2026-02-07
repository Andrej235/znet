const SharedSlice = @import("../utils/shared_slice.zig").SharedSlice;

const MessageData = union(enum) {
    single: []const u8,
    shared: SharedSlice(u8),
};

pub const OutMessage = struct {
    offset: usize,
    data: MessageData,
};
