const std = @import("std");
const Audience = @import("audience.zig").Audience;
const ClientConnection = @import("../client_connection.zig").ClientConnection;
const Queue = @import("../../utils/mpmc_queue.zig").Queue;

pub const Clients = struct {
    allocator: std.mem.Allocator,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    sender_id: u32,
    wakeup_fd: std.posix.fd_t,

    pub fn sender(self: *Clients) !Audience {
        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .connected_clients = self.connected_clients,
            .wakeup_fd = self.wakeup_fd,
            .audience_type = .sender,
            .sender_id = self.sender_id,
        };
    }

    pub fn others(self: *Clients) !Audience {
        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .connected_clients = self.connected_clients,
            .wakeup_fd = self.wakeup_fd,
            .audience_type = .others,
            .sender_id = self.sender_id,
        };
    }

    pub fn all(self: *Clients) !Audience {
        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .connected_clients = self.connected_clients,
            .wakeup_fd = self.wakeup_fd,
            .audience_type = .all,
            .sender_id = self.sender_id,
        };
    }
};
