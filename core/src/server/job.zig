const ConnectionId = @import("connection_id.zig").ConnectionId;

pub const Job = struct {
    data: []const u8,
    buffer_idx: u32,
    client_id: ConnectionId,
};
