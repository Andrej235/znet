const ConnectionId = @import("connection_id.zig").ConnectionId;

pub const Job = struct {
    data: []const u8,
    client_id: ConnectionId,
};
