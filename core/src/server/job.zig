const ConnectionId = @import("connection_id.zig").ConnectionId;
const Request = @import("requests/request.zig").Request;

pub const Job = struct {
    buffer_idx: u32,
    client_id: ConnectionId,
    request: Request,
};
