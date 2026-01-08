const std = @import("std");
const ClientConnection = @import("../client-connection.zig").ClientConnection;
const BroadcastJob = @import("../broadcast-job.zig").BroadcastJob;
const Queue = @import("../../utils/mpmc-queue.zig").Queue;

pub const Audience = struct {
    client_connections: []const ClientConnection,
    selected_bitset: std.bit_set.DynamicBitSet,
    broadcast_job_queue: *Queue(BroadcastJob),

    pub fn broadcast(self: *Audience) !void {
        while (self.selected_bitset.findFirstSet()) |idx| {
            std.debug.print("broadcast to: {}\n", .{idx});
            self.selected_bitset.unset(idx);
        }
    }
};
