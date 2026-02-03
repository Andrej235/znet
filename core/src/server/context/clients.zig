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
        var bitset = try std.bit_set.DynamicBitSet.initEmpty(self.allocator, self.client_connections.len);
        bitset.set(self.sender_id);

        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .selected_bitset = bitset,
            .wakeup_fd = self.wakeup_fd,
        };
    }

    pub fn others(self: *Clients) !Audience {
        var bitset = try std.bit_set.DynamicBitSet.initEmpty(self.allocator, self.client_connections.len);
        for (self.connected_clients) |client_id| {
            bitset.set(client_id);
        }
        bitset.unset(self.sender_id);

        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .selected_bitset = bitset,
            .wakeup_fd = self.wakeup_fd,
        };
    }

    pub fn all(self: *Clients) !Audience {
        var bitset = try std.bit_set.DynamicBitSet.initEmpty(self.allocator, self.client_connections.len);
        for (self.connected_clients) |client_id| {
            bitset.set(client_id);
        }

        return Audience{
            .allocator = self.allocator,
            .client_connections = self.client_connections,
            .selected_bitset = bitset,
            .wakeup_fd = self.wakeup_fd,
        };
    }
};
