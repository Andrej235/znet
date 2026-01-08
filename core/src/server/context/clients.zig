const std = @import("std");
const Audience = @import("audience.zig").Audience;
const ClientConnection = @import("../client-connection.zig").ClientConnection;
const BroadcastJob = @import("../broadcast-job.zig").BroadcastJob;
const Queue = @import("../../utils/mpmc-queue.zig").Queue;

const Clients = struct {
    allocator: std.mem.Allocator,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    sender_id: u32,
    broadcast_job_queue: *Queue(BroadcastJob),

    pub fn sender(self: *Clients) Audience {
        _ = self;
        return Audience{};
    }

    pub fn others(self: *Clients) Audience {
        _ = self;
        return Audience{};
    }

    pub fn all(self: *Clients) Audience {
        _ = self;
        return Audience{};
    }
};
