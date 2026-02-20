const std = @import("std");
const Audience = @import("audience.zig").Audience;
const ClientConnection = @import("../client_connection.zig").ClientConnection;
const Queue = @import("../../utils/mpmc_queue.zig").Queue;
const Waker = @import("../../waker/waker.zig");

pub const Clients = struct {
    allocator: std.mem.Allocator,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    sender_id: u32,
    waker: Waker,

    pub fn sender(self: *Clients) !Audience {
        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .connected_clients = self.connected_clients,
            .waker = self.waker,
            .audience_type = .sender,
            .sender_id = self.sender_id,
        };
    }

    pub fn others(self: *Clients) !Audience {
        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .connected_clients = self.connected_clients,
            .waker = self.waker,
            .audience_type = .others,
            .sender_id = self.sender_id,
        };
    }

    pub fn all(self: *Clients) !Audience {
        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .connected_clients = self.connected_clients,
            .waker = self.waker,
            .audience_type = .all,
            .sender_id = self.sender_id,
        };
    }
};
