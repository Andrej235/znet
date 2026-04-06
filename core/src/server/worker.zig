const std = @import("std");

const Queue = @import("../queues/spmc_queue.zig").Queue;
const Job = @import("job.zig").Job;
const OutMessage = @import("out_message.zig").OutMessage;

const Semaphore = @import("../semaphore/semaphore.zig").Semaphore;
const Waker = @import("../waker/waker.zig");

const Logger = @import("../logger/logger.zig").Logger.scoped(.worker_thread);

const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const ClientConnection = @import("client_connection.zig").ClientConnection;
const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const RuntimeScope = @import("../app/scope/runtime_scope.zig").RuntimeScope;

const ShutdownState = @import("server.zig").ShutdownState;

pub fn Worker(comptime TApp: type) type {
    const call_table: []const RuntimeScope = TApp.compileServerCallTable();

    return struct {
        const Self = @This();

        thread: std.Thread,

        allocator: std.mem.Allocator,

        job_queue: *Queue(Job),
        semaphore: *Semaphore,
        shutdown_state: *std.atomic.Value(ShutdownState),
        io_waker: Waker,

        clients: []ClientConnection,
        input_buffer_pool: *BufferPool,
        output_buffer_pool: *BufferPool,

        current_buffer: []u8, // only valid if current_buffer_idx != null
        current_buffer_idx: ?u32,

        pub fn init(
            allocator: std.mem.Allocator,
            job_queue: *Queue(Job),
            semaphore: *Semaphore,
            shutdown_state: *std.atomic.Value(ShutdownState),
            io_waker: Waker,
            clients: []ClientConnection,
            input_buffer_pool: *BufferPool,
            output_buffer_pool: *BufferPool,
        ) Self {
            return .{
                .thread = undefined,

                .allocator = allocator,

                .job_queue = job_queue,
                .semaphore = semaphore,
                .shutdown_state = shutdown_state,
                .io_waker = io_waker,

                .clients = clients,
                .input_buffer_pool = input_buffer_pool,
                .output_buffer_pool = output_buffer_pool,

                .current_buffer = undefined,
                .current_buffer_idx = null,
            };
        }

        fn stop(self: *Self) void {
            if (self.current_buffer_idx) |idx| {
                self.output_buffer_pool.release(idx);
            }
        }

        pub inline fn runThread(self: *Self, io_thread_id: usize, worker_id: usize) !void {
            const thread = try std.Thread.spawn(.{}, Self.run, .{self});

            var name_buff: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(name_buff[0..], "io-{}-worker-{}", .{ io_thread_id, worker_id });
            thread.setName(name) catch |err| {
                Logger.err("Failed to set thread name to {s}: {}", .{ name, err });
            };

            self.thread = thread;
        }

        fn run(self: *Self) !void {
            while (false) { // todo: reimplement
                // input buffer released in handler right after deserialization

                self.semaphore.acquire();
                if (self.shutdown_state.load(.acquire) == .immediate) {
                    self.stop();
                    return;
                }
                const job = self.job_queue.tryPop() orelse continue;

                var reader: std.Io.Reader = .fixed(job.data);
                const headers = deserializeMessageHeaders(&reader) catch |err| {
                    Logger.err("Failed to deserialize message headers: {}", .{err});
                    self.input_buffer_pool.release(job.buffer_idx);
                    continue;
                };

                const req_headers = headers.Request; // reactor only passes valid requests to the workers

                if (self.current_buffer_idx == null) {
                    const buffer_idx = self.output_buffer_pool.acquire() orelse {
                        // no output buffers available, drop the message and release the input buffer
                        self.input_buffer_pool.release(job.buffer_idx);

                        Logger.info("No output buffers available, dropping message", .{});
                        continue;
                    };

                    self.current_buffer_idx = buffer_idx;
                    self.current_buffer = self.output_buffer_pool.buffer(buffer_idx);
                }

                const handler = call_table[req_headers.contract_id][req_headers.method_id].handler;

                var writer: std.Io.Writer = .fixed(self.current_buffer);
                try handler(
                    .{
                        .allocator = self.allocator,
                        .input_buffer_pool = self.input_buffer_pool,
                        .waker = self.io_waker,
                    },
                    req_headers,
                    &reader,
                    &writer,
                    job.buffer_idx,
                );

                const response_payload_len = std.mem.readInt(u32, self.current_buffer[MessageHeadersByteSize.Response - 4 .. MessageHeadersByteSize.Response], .big);
                const response_data = self.current_buffer[0 .. MessageHeadersByteSize.Response + response_payload_len];

                // response_data will be freed by the io thread after sending
                var client = self.clients[job.client_id.index];

                try client.enqueueMessage(OutMessage{
                    .offset = 0,
                    .data = .{
                        .single = .{
                            .data = response_data,
                            .buffer_idx = self.current_buffer_idx.?,
                        },
                    },
                });

                self.current_buffer_idx = null; // released in the io thread, set to null here to indicate that we don't have a current buffer anymore
            }
        }
    };
}
