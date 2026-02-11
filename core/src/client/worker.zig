const std = @import("std");

const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;
const BroadcastHandlerFn = @import("handler_fn/broadcast_handler_fn.zig");
const Queue = @import("../utils/mpmc_queue.zig").Queue;
const Client = @import("client.zig").Client;

pub const Worker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread = undefined,
    client: *Client,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *Client,
    ) Worker {
        return Worker{
            .allocator = allocator,
            .client = client,
        };
    }

    pub inline fn runThread(self: *Worker) !void {
        const thread = try std.Thread.spawn(.{}, Worker.run, .{self});
        self.thread = thread;
    }

    fn run(self: *Worker) !void {
        const client = self.client;

        while (true) {
            const in_msg = client.inbound_queue.pop() catch |err| {
                switch (err) {
                    error.Closed => return,
                }
            };

            defer self.client.inbound_buffer_pool.release(in_msg.buffer_idx);
            var reader = std.io.Reader.fixed(in_msg.data);
            const headers = try deserializeMessageHeaders(&reader);

            switch (headers) {
                .Request => {
                    std.debug.print("Unexpected Request message found in inbound queue\n", .{});
                    return;
                },
                .Response => |response| {
                    if (client.pending_requests_map.get(response.request_id)) |pending_request| {
                        pending_request.resolve(&client.deserializer, &reader, pending_request.promise) catch |err| {
                            std.debug.print("Error resolving request_id {d}: {}\n", .{ response.request_id, err });
                        };

                        _ = client.pending_requests_map.remove(response.request_id);
                    } else {
                        std.debug.print("No pending request found for request_id: {d}\n", .{response.request_id});
                    }
                },
                .Broadcast => |broadcast| {
                    if (Client.call_table.len == 0) return;

                    const handler = Client.call_table[broadcast.contract_id][broadcast.method_id];
                    try handler(client, self.allocator, &reader);
                },
            }
        }
    }
};
