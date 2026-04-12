pub const OutMessage = struct {
    offset: usize,
    data: []const u8,
    buffer_idx: u32,
    keep_alive: bool,
};
