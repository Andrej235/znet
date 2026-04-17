const ConnectionId = @import("connection_id.zig").ConnectionId;
const Request = @import("../requests/request.zig").Request;
const Match = @import("../router/router.zig").Router.Match;

pub const WorkerJob = struct {
    buffer_idx: u32,
    client_id: ConnectionId,
    request: Request,
    match: Match,
};
