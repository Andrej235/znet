const ConnectionId = @import("connection-id.zig").ConnectionId;

pub const JobResult = struct {
    client_id: ConnectionId,
    data: []const u8,
};
