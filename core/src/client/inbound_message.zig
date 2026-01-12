pub const InboundMessage = union(enum) {
    payload: []const u8,
};
