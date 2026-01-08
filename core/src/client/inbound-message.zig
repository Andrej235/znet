pub const InboundMessage = union(enum) {
    response: struct {
        request_id: u32,
        payload: []const u8,
    },
    broadcast: struct {
        payload: []const u8,
    },
};
