const std = @import("std");
const Audience = @import("audience.zig").Audience;
const ClientConnection = @import("../client-connection.zig").ClientConnection;
const BroadcastJob = @import("../broadcast-job.zig").BroadcastJob;
const Queue = @import("../../utils/mpmc-queue.zig").Queue;

pub const Clients = struct {
    allocator: std.mem.Allocator,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    sender_id: u32,
    broadcast_job_queue: *Queue(BroadcastJob),

    pub fn sender(self: *Clients) !Audience {
        var bitset = try std.bit_set.DynamicBitSet.initEmpty(self.allocator, self.client_connections.len);
        bitset.set(self.sender_id);

        return Audience{
            .broadcast_job_queue = self.broadcast_job_queue,
            .client_connections = self.client_connections,
            .selected_bitset = bitset,
        };
    }

    pub fn others(self: *Clients) !Audience {
        var bitset = try std.bit_set.DynamicBitSet.initEmpty(self.allocator, self.client_connections.len);
        for (self.connected_clients) |client_id| {
            std.debug.print("{}-{}\n", .{ client_id, self.client_connections.len });
            bitset.set(client_id);
        }
        bitset.unset(self.sender_id);

        return Audience{
            .broadcast_job_queue = self.broadcast_job_queue,
            .client_connections = self.client_connections,
            .selected_bitset = bitset,
        };
    }

    pub fn all(self: *Clients) !Audience {
        var bitset = try std.bit_set.DynamicBitSet.initEmpty(self.allocator, self.client_connections.len);
        for (self.connected_clients) |client_id| {
            bitset.set(client_id);
        }

        return Audience{
            .broadcast_job_queue = self.broadcast_job_queue,
            .client_connections = self.client_connections,
            .selected_bitset = bitset,
        };
    }
};
