const std = @import("std");

const Queue = @import("../utils/mpmc_queue.zig").Queue;
const Job = @import("job.zig").Job;
const OutMessage = @import("out_message.zig").OutMessage;

const HandlerFn = @import("handler_fn/handler_fn.zig").HandlerFn;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const Server = @import("server.zig").Server;

pub const Worker = struct {
    thread: std.Thread = undefined,

    server: *Server,
    allocator: std.mem.Allocator,

    job_queue: *Queue(Job),
    wakeup_fd: std.posix.fd_t,

    call_table: []const []const HandlerFn,

    current_buffer: []u8, // only valid if current_buffer_idx != null
    current_buffer_idx: ?u32,

    pub fn init(server: *Server) Worker {
        return .{
            .server = server,
            .allocator = server.allocator,

            .job_queue = server.job_queue,
            .wakeup_fd = server.wakeup_fd,

            .call_table = Server.call_table,

            .current_buffer = undefined,
            .current_buffer_idx = null,
        };
    }

    pub fn deinit(self: *Worker) void {
        if (self.current_buffer_idx) |idx| {
            self.server.output_buffer_pool.release(idx);
        }
    }

    pub inline fn runThread(self: *Worker) !void {
        const thread = try std.Thread.spawn(.{}, Worker.run, .{self});
        self.thread = thread;
    }

    fn run(self: *Worker) !void {
        while (true) {
            // input buffer released in handler right after deserialization

            const job = self.job_queue.pop() catch |err| {
                switch (err) {
                    error.Closed => return,
                }
            };

            var reader: std.Io.Reader = .fixed(job.data);
            const headers = deserializeMessageHeaders(&reader) catch |err| {
                std.debug.print("Failed to deserialize message headers: {}\n", .{err});
                self.server.input_buffer_pool.release(job.buffer_idx);
                continue;
            };

            if (headers != .Request) return error.UnexpectedMessageHeader;
            const req_header = headers.Request;

            var client = &self.server.clients[job.client_id.index];
            if (client.id.gen != job.client_id.gen) {
                std.debug.print("Client gen mismatch: expected {}, got {}\n", .{ client.id.gen, job.client_id.gen });
                self.server.input_buffer_pool.release(job.buffer_idx);
                continue;
            }

            if (self.current_buffer_idx == null) {
                // todo: handle output buffer exhaustion more gracefully, right now we just drop the message, which will cause the client to wait indefinitely until it hits a timeout
                const buffer_idx = self.server.output_buffer_pool.acquire() orelse {
                    self.server.input_buffer_pool.release(job.buffer_idx);
                    continue;
                };

                self.current_buffer_idx = buffer_idx;
                self.current_buffer = self.server.output_buffer_pool.buffer(buffer_idx);
            }

            const handler = self.call_table[req_header.contract_id][req_header.method_id];

            var writer: std.Io.Writer = .fixed(self.current_buffer);
            try handler(
                self.allocator,
                self.server,
                job.client_id.index,
                headers.Request,
                &reader,
                &writer,
                job.buffer_idx,
            );

            const response_payload_len = std.mem.readInt(u32, self.current_buffer[MessageHeadersByteSize.Response - 4 .. MessageHeadersByteSize.Response], .big);
            const response_data = self.current_buffer[0 .. MessageHeadersByteSize.Response + response_payload_len];

            // response_data will be freed by the reactor thread after sending
            try client.enqueueMessage(OutMessage{
                .offset = 0,
                .data = .{
                    .single = .{
                        .data = response_data,
                        .buffer_idx = self.current_buffer_idx.?,
                    },
                },
            });

            self.current_buffer_idx = null; // released in reactor thread, set to null here to indicate that we don't have a current buffer anymore
        }
    }
};
