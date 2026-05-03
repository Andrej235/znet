const std = @import("std");

const Queue = @import("../queues/spmc_queue.zig").Queue;
const WorkerJob = @import("worker_job.zig").WorkerJob;
const OutMessage = @import("out_message.zig").OutMessage;

const Semaphore = @import("../semaphore/semaphore.zig").Semaphore;
const Waker = @import("../waker/waker.zig");

const Logger = @import("../logger/logger.zig").Logger.scoped(.worker_thread);

const ClientConnection = @import("client_connection.zig").ClientConnection;
const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;

const ShutdownState = @import("server.zig").ShutdownState;

pub const Worker = struct {
    thread: std.Thread,

    allocator: std.mem.Allocator,

    job_queue: *Queue(WorkerJob),
    semaphore: *Semaphore,
    shutdown_state: *std.atomic.Value(ShutdownState),
    io_waker: Waker,

    clients: []ClientConnection,
    input_buffer_pool: *BufferPool,
    output_buffer_pool: *BufferPool,

    current_output_buffer: []u8, // only valid if current_buffer_idx != null
    current_output_buffer_idx: ?u32,

    pub fn init(
        allocator: std.mem.Allocator,
        job_queue: *Queue(WorkerJob),
        semaphore: *Semaphore,
        shutdown_state: *std.atomic.Value(ShutdownState),
        io_waker: Waker,
        clients: []ClientConnection,
        input_buffer_pool: *BufferPool,
        output_buffer_pool: *BufferPool,
    ) Worker {
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

            .current_output_buffer = undefined,
            .current_output_buffer_idx = null,
        };
    }

    fn stop(self: *Worker) void {
        if (self.current_output_buffer_idx) |idx| {
            self.output_buffer_pool.release(idx);
        }
    }

    pub inline fn runThread(self: *Worker, io_thread_id: usize, worker_id: usize) !void {
        const thread = try std.Thread.spawn(.{}, Worker.run, .{self});

        var name_buff: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(name_buff[0..], "io-{}-worker-{}", .{ io_thread_id, worker_id });
        thread.setName(name) catch |err| {
            Logger.err("Failed to set thread name to {s}: {}", .{ name, err });
        };

        self.thread = thread;
    }

    fn run(self: *Worker) !void {
        while (true) {
            self.semaphore.acquire();
            if (self.shutdown_state.load(.acquire) == .immediate) {
                self.stop();
                return;
            }
            const job = self.job_queue.tryPop() orelse continue;

            if (self.current_output_buffer_idx == null) {
                const buffer_idx = self.output_buffer_pool.acquire() orelse {
                    // no output buffers available, drop the message and release the input buffer
                    self.input_buffer_pool.release(job.buffer_idx);

                    Logger.info("No output buffers available, dropping message", .{});
                    continue;
                };

                self.current_output_buffer_idx = buffer_idx;
                self.current_output_buffer = self.output_buffer_pool.buffer(buffer_idx);
            }

            switch (job.request) {
                .http => |http_request| {
                    const match = job.match;
                    var client = self.clients[job.client_id.index];

                    var writer: std.Io.Writer = .fixed(self.current_output_buffer);
                    const bytes_written = match.action.handler(
                        .{
                            .allocator = self.allocator,
                            .waker = self.io_waker,

                            .connection = http_request.connection,

                            .body = http_request.body,
                            .chunked_body = http_request.chunked,
                            .body_content_type = http_request.content_type,

                            .output_writer = &writer,
                            .accepts = http_request.accepts,

                            .param_iterator = match.params,
                            .query = match.query,
                        },
                    ) catch |err| {
                        // keep the current output buffer to avoid just re-acquiring it in the next iteration
                        // release the input buffer

                        self.input_buffer_pool.release(job.buffer_idx);
                        Logger.warn("Action at {s} failed with error: {}", .{ match.action.path, err });
                        continue;
                    };

                    // release the input buffer
                    self.input_buffer_pool.release(job.buffer_idx);

                    const response_data = self.current_output_buffer[0..bytes_written];

                    // response_data will be freed by the io thread after sending
                    client.enqueueMessage(OutMessage{
                        .offset = 0,
                        .data = response_data,
                        .buffer_idx = self.current_output_buffer_idx.?,
                        .keep_alive = http_request.connection == .keep_alive,
                    }) catch {
                        // client's response queue is full
                        // we can't really do anything about it, so just move on to the next job
                        // keep the current output buffer to avoid just re-acquiring it in the next iteration
                        continue;
                    };

                    // released in the io thread, set to null here to indicate that we don't have a current buffer anymore
                    self.current_output_buffer_idx = null;
                },
            }
        }
    }
};
