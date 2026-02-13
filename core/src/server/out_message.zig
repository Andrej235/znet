const SharedSlice = @import("../utils/shared_slice.zig").SharedSlice;

const MessageData = union(enum) {
    single: BorrowedBuffer,
    shared: SharedSlice(u8),
};

const BorrowedBuffer = struct {
    data: []const u8,
    buffer_idx: u32,
};

pub const OutMessage = struct {
    offset: usize,
    data: MessageData,
};
