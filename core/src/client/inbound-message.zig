pub const InboundMessage = struct {
    request_id: u32,
    payload: []const u8,
};
