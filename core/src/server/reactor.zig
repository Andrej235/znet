const std = @import("std");
const http = @import("../http/http.zig");
const posix = std.posix;
const builtin = @import("builtin");

const Http1Parser = @import("./parsers/http1.zig").Http1Parser;

const HostRouter = @import("../app/host_router.zig").HostRouter;
const Listener = @import("../listener/listener.zig");
const Poller = @import("../poller/poller.zig");
const SPMCQueue = @import("../queues/spmc_queue.zig").Queue;
const SPSCQueue = @import("../queues/spsc_queue.zig").Queue;
const Semaphore = @import("../semaphore/semaphore.zig").Semaphore;
const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const Waker = @import("../waker/waker.zig");
const ClientConnection = @import("client_connection.zig").ClientConnection;
const ConnectionId = @import("connection_id.zig").ConnectionId;
const Job = @import("job.zig").Job;
const OutMessage = @import("out_message.zig").OutMessage;
const ServerOptions = @import("server_options.zig").ServerOptions;
const ShutdownState = @import("server.zig").ShutdownState;
const Worker = @import("worker.zig").Worker;

const Response = @import("../responses/response.zig").Response;
const HttpResponse = @import("../responses/http.zig").HttpResponse;
const ResponseWriter = @import("../responses/response_writer.zig").ResponseWriter;

const Logger = @import("../logger/logger.zig").Logger.scoped(.reactor);

pub const ReactorHandle = struct {
    waker: Waker,
    thread: std.Thread,
};

pub const ReactorContext = struct {
    allocator: std.mem.Allocator,
    input_buffer_pool: *BufferPool,
    waker: Waker,
};

pub fn Reactor(comptime TApp: type) type {
    return struct {
        const Self = @This();

        options: ServerOptions,
        allocator: std.mem.Allocator,
        router: *const HostRouter,

        // number of connected clients
        connected: usize,

        poller: Poller,

        // stack of free connection indices, LIFO
        free_indices: []ConnectionId,

        // number of free indices in free_indices
        free_count: u32,

        clients: []ClientConnection,

        waker: Waker,

        // used by the server to coordinate shutdown between all threads
        shutdown_state: *std.atomic.Value(ShutdownState),

        input_buffer_pool: *BufferPool,
        output_buffer_pool: *BufferPool,

        job_queue: *SPSCQueue(Job),

        current_output_buffer: []u8, // only valid if current_output_buffer_idx != null
        current_output_buffer_idx: ?u32,

        // worker pool
        workers: []Worker(TApp),
        worker_pool_job_queue: *SPMCQueue(Job),
        worker_pool_semaphore: Semaphore,

        pub fn init(
            allocator: std.mem.Allocator,
            address: std.net.Address,
            shutdown_state: *std.atomic.Value(ShutdownState),
            io_thread_id: usize,
            options: ServerOptions,
            ready_count: *std.atomic.Value(u32),
            router: *const HostRouter,
        ) !ReactorHandle {
            const waker = try Waker.init();

            const thread = try std.Thread.spawn(.{}, startThread, .{
                allocator,
                address,
                shutdown_state,
                waker,
                io_thread_id,
                options,
                ready_count,
                router,
            });

            var name_buff: [8]u8 = undefined;
            const name = try std.fmt.bufPrint(name_buff[0..], "io-{}", .{io_thread_id});
            thread.setName(name) catch |err| {
                Logger.err("Failed to set thread name to {s}: {}", .{ name, err });
            };

            return .{
                .waker = waker,
                .thread = thread,
            };
        }

        fn stop(self: *Self) !void {
            // kick the clients, release their buffers, and close their sockets
            for (0..self.connected) |i| {
                Logger.info("kicked client due to shutdown {}", .{i});
                self.removeClient(0);
            }

            self.worker_pool_semaphore.batchRelease(@intCast(self.workers.len));
            for (self.workers) |*w| {
                // workers use the same shutdown signal as the reactor thread
                w.thread.join();
            }
            self.allocator.free(self.workers);

            self.waker.deinit();

            self.input_buffer_pool.deinit(self.allocator);
            self.allocator.destroy(self.input_buffer_pool);

            self.output_buffer_pool.deinit(self.allocator);
            self.allocator.destroy(self.output_buffer_pool);

            self.worker_pool_job_queue.deinit(self.allocator);
            self.allocator.destroy(self.worker_pool_job_queue);

            self.job_queue.deinit(self.allocator);
            self.allocator.destroy(self.job_queue);

            self.allocator.free(self.clients);
            self.allocator.free(self.free_indices);
            self.poller.deinit();

            self.allocator.destroy(self);
        }

        fn startThread(
            allocator: std.mem.Allocator,
            address: std.net.Address,
            shutdown_state: *std.atomic.Value(ShutdownState),
            waker: Waker,
            io_thread_id: usize,
            options: ServerOptions,
            ready_count: *std.atomic.Value(u32),
            router: *const HostRouter,
        ) !void {
            // pin thread to a specific cpu core to improve cache locality and reduce latency
            // this needs to be done before any allocations to ensure memory is allocated in the local NUMA node (first touch policy)
            if (comptime builtin.os.tag == .linux) {
                const linux = comptime std.os.linux;
                var mask: [16]u64 = .{0} ** 16;

                const idx = io_thread_id / 64;
                const bit = io_thread_id % 64;

                mask[idx] |= @as(usize, @intCast(1)) << @as(u6, @intCast(bit));

                const tid = linux.gettid();

                // pin thread to cpu core
                try linux.sched_setaffinity(
                    tid,
                    &mask,
                );
            }

            const clients = try allocator.alloc(ClientConnection, options.max_clients);
            errdefer allocator.free(clients);

            var poller = try Poller.init(allocator, options.max_clients + 2); // +2 for the listening socket and the wakeup socket
            errdefer poller.deinit();

            const job_queue = try allocator.create(SPSCQueue(Job));
            job_queue.* = try SPSCQueue(Job).init(allocator, options.max_jobs_in_queue);
            errdefer allocator.destroy(job_queue);

            var free_indices = try allocator.alloc(ConnectionId, options.max_clients);
            errdefer allocator.free(free_indices);
            for (0..options.max_clients) |i| {
                free_indices[i] = .{ .index = @intCast(i), .gen = 0 };
            }

            const input_buffer_pool = try allocator.create(BufferPool);
            input_buffer_pool.* = try BufferPool.init(
                allocator,
                options.max_jobs_in_queue,
                options.client_read_buffer_size,
            );
            errdefer input_buffer_pool.deinit(allocator);
            errdefer allocator.destroy(input_buffer_pool);

            const output_buffer_pool = try allocator.create(BufferPool);
            output_buffer_pool.* = try BufferPool.init(
                allocator,
                options.max_jobs_in_queue,
                options.job_result_buffer_size,
            );
            errdefer output_buffer_pool.deinit(allocator);
            errdefer allocator.destroy(output_buffer_pool);

            // worker pool
            const workers = try allocator.alloc(Worker(TApp), options.worker_pool_size_per_io);
            errdefer allocator.free(workers);

            const worker_pool_job_queue = try allocator.create(SPMCQueue(Job));
            worker_pool_job_queue.* = try SPMCQueue(Job).init(allocator, options.max_jobs_in_queue);
            errdefer worker_pool_job_queue.deinit(allocator);
            errdefer allocator.destroy(worker_pool_job_queue);

            const worker_pool_semaphore = Semaphore.init(0);

            const self = try allocator.create(Self);
            self.* = Self{
                .options = options,
                .allocator = allocator,

                .clients = clients,
                .free_indices = free_indices,
                .free_count = options.max_clients,
                .connected = 0,

                .job_queue = job_queue,

                .waker = waker,
                .poller = poller,
                .shutdown_state = shutdown_state,

                .input_buffer_pool = input_buffer_pool,
                .output_buffer_pool = output_buffer_pool,

                .current_output_buffer = undefined,
                .current_output_buffer_idx = null,

                .workers = workers,
                .worker_pool_job_queue = worker_pool_job_queue,
                .worker_pool_semaphore = worker_pool_semaphore,

                .router = router,
            };

            for (workers, 0..) |*w, i| {
                w.* = Worker(TApp).init(
                    allocator,
                    worker_pool_job_queue,
                    &self.worker_pool_semaphore,
                    shutdown_state,
                    waker,
                    clients,
                    input_buffer_pool,
                    output_buffer_pool,
                );
                try w.runThread(io_thread_id, i);
            }

            try self.run(address, ready_count);
        }

        fn run(self: *Self, address: std.net.Address, ready_reactors_count: *std.atomic.Value(u32)) !void {
            var listener = try Listener.init(address);
            defer listener.deinit();
            errdefer self.stop() catch |err| {
                Logger.err("Failed to stop io thread: {}", .{err});
            };

            // polling slot with index self.options.max_clients is reserved for the listening socket
            try listener.register(&self.poller, self.options.max_clients);

            // polling slot with index self.options.max_clients + 1 is reserved for the wakeup fd
            try self.waker.register(&self.poller, self.options.max_clients + 1);

            // signal to the server that this reactor thread is ready to accept connections and process jobs
            // this is used to coordinate the startup of multiple reactor threads
            _ = ready_reactors_count.fetchAdd(1, .release);

            while (true) {
                // no timeout
                var iterator = self.poller.wait(-1);

                while (iterator.next()) |event| {
                    const idx = event.index;

                    if (idx == self.options.max_clients) { // listening socket
                        // listening socket is ready, accept new connections
                        try listener.drainAccepts(self);
                        continue;
                    }

                    if (idx == self.options.max_clients + 1) { // wakeup fd
                        // either the server shutdown or there are new jobs to process

                        if (self.shutdown_state.load(.acquire) == .immediate) {
                            // shutdown
                            try self.stop();
                            return;
                        }

                        // handle new jobs
                        while (self.job_queue.tryPop()) |job| {
                            // input buffer will be released after executing the handler
                            // doing it in the handler would allow for faster buffer cycling but would force allocations for header and path parsing

                            const client = &self.clients[job.client_id.index];
                            if (client.id.gen != job.client_id.gen) {
                                // job was meant for a previous generation of the client, just release the buffer as there is no point in processing it
                                self.input_buffer_pool.release(job.buffer_idx);

                                Logger.info("Client gen mismatch: expected {}, got {}", .{ client.id.gen, job.client_id.gen });
                                continue;
                            }

                            switch (job.request) {
                                .http => |http_request| {
                                    Logger.debug("Received HTTP request: {} {s}", .{ http_request.method, http_request.path });

                                    const match = self.router.lookup(&http_request.host, http_request.path, http_request.method) catch |err| switch (err) {
                                        error.HostNotFound => {
                                            self.sendErrorToClient(
                                                client,
                                                .bad_request,
                                                http_request.connection,
                                                ClientError{
                                                    .message = "Host not found",
                                                    .details = &[_]ClientErrorDetails{
                                                        .{
                                                            .source = "router",
                                                            .message = "No matching host found for the given host header",
                                                        },
                                                    },
                                                    .truncated = false,
                                                },
                                            ) catch {
                                                // no output buffers available or the client's response queue is full
                                                self.input_buffer_pool.release(job.buffer_idx);
                                                Logger.info("No output buffers available, dropping message", .{});
                                            };

                                            continue;
                                        },

                                        error.PathNotFound => {
                                            self.sendErrorToClient(client, .not_found, http_request.connection, null) catch {
                                                // no output buffers available or the client's response queue is full
                                                self.input_buffer_pool.release(job.buffer_idx);
                                                Logger.info("No output buffers available, dropping message", .{});
                                            };

                                            continue;
                                        },
                                    };
                                    switch (match.action.executor) {
                                        .io => { // execute the action on the reactor thread
                                            // acquire a new output buffer if needed
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

                                            var writer: std.Io.Writer = .fixed(self.current_output_buffer);
                                            const bytes_written = match.action.handler(
                                                .{
                                                    .allocator = self.allocator,
                                                    .waker = self.waker,

                                                    .connection = http_request.connection,

                                                    .body = http_request.body,
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

                                            // released in reactor thread, set to null here to indicate that we don't have a current buffer anymore
                                            self.current_output_buffer_idx = null;
                                        },
                                        .worker_pool => { // pass the job over to the worker pool, guaranteed to be a valid request
                                            self.worker_pool_job_queue.tryPush(job) catch {
                                                // queue full, drop the message and release the input buffer
                                                self.input_buffer_pool.release(job.buffer_idx);

                                                Logger.info("Worker pool job queue full, dropping message", .{});
                                                continue;
                                            };

                                            self.worker_pool_semaphore.release();
                                        },
                                    }
                                },
                            }
                        }

                        // nothing left to send, clear the eventfd
                        if (self.job_queue.isEmpty())
                            try self.waker.drain();

                        continue;
                    }

                    // client
                    const client_idx = idx;
                    var client = &self.clients[client_idx];

                    if (event.in) {
                        // this socket is ready to be read, fairness is implemented in client.readMessage()
                        client.readMessage() catch |err| {
                            switch (err) {
                                error.Closed, error.ConnectionResetByPeer => {
                                    Logger.info("[{f} | {}/{}] disconnected", .{ client.address.in, client_idx, client.id.gen });

                                    // removeClient will swap the last client into position i, do not increment i
                                    self.removeClient(client_idx);
                                    continue; // move on to the next client
                                },

                                Http1Parser.Errors.MissingHostHeader,

                                Http1Parser.Errors.InvalidHeaders,
                                Http1Parser.Errors.InvalidRequestLine,
                                Http1Parser.Errors.InvalidHostHeader,

                                Http1Parser.Errors.UnsupportedMethod,
                                Http1Parser.Errors.UnsupportedTransferEncoding,
                                Http1Parser.Errors.UnsupportedVersion,
                                => {
                                    self.sendErrorToClient(
                                        client,
                                        .bad_request,
                                        .keep_alive,
                                        ClientError{
                                            .message = "Failed to parse HTTP request",
                                            .details = &[_]ClientErrorDetails{
                                                .{
                                                    .source = "http_parser",
                                                    .message = switch (err) {
                                                        Http1Parser.Errors.MissingHostHeader => "Missing host header",
                                                        Http1Parser.Errors.InvalidHeaders => "Invalid headers",
                                                        Http1Parser.Errors.InvalidRequestLine => "Invalid request line",
                                                        Http1Parser.Errors.InvalidHostHeader => "Invalid host header",
                                                        Http1Parser.Errors.UnsupportedMethod => "Unsupported method",
                                                        Http1Parser.Errors.UnsupportedTransferEncoding => "Unsupported transfer encoding",
                                                        Http1Parser.Errors.UnsupportedVersion => "Unsupported version",
                                                        else => unreachable,
                                                    },
                                                },
                                            },
                                            .truncated = false,
                                        },
                                    ) catch continue;
                                },

                                else => {
                                    Logger.err("Error reading from client {}: {}", .{ client_idx, err });

                                    // removeClient will swap the last client into position i, do not increment i
                                    self.removeClient(client_idx);
                                    continue; // move on to the next client
                                },
                            }
                        };
                    }

                    if (event.out) {
                        // has messages to send and can accept being written to
                        const latest_out_message = client.out_message_queue.tryPeek();

                        // has messages queued to send
                        if (latest_out_message) |out| {
                            var sent: usize = 0;
                            while (out.offset < out.data.len and sent < self.options.max_write_per_tick) {
                                const n = posix.send(client.socket, out.data[out.offset..], 0) catch |err| switch (err) {
                                    error.WouldBlock => break,
                                    else => return err,
                                };

                                if (n == 0) break; // socket closed?

                                sent += n;
                                out.offset += n;
                            }

                            if (out.offset >= out.data.len) {
                                // message fully sent, remove it from the queue
                                _ = client.out_message_queue.tryPop();
                                self.output_buffer_pool.release(out.buffer_idx);
                            }

                            if (!out.keep_alive) {
                                // client requested connection close or sent a malformed request, close the connection after sending the response
                                Logger.info("[{f} | {}/{}] disconnected (due to keep_alive)", .{ client.address.in, client_idx, client.id.gen });
                                self.removeClient(client_idx);
                                continue; // move on to the next client
                            }

                            if (client.out_message_queue.isEmpty()) {
                                // no more messages left to send to this client
                                self.poller.modify(client.socket, client_idx, true, false) catch |err| {
                                    Logger.err("Failed to modify poller for client {}: {}", .{ client_idx, err });
                                };
                            }
                        }
                    }
                }
            }

            Logger.err("Exited main reactor loop without going through proper shutdown path", .{});
            try self.stop();
        }

        pub fn attachClientSocket(self: *Self, socket: posix.socket_t, address: std.net.Address) !void {
            const idx = self.popIndex();
            if (idx == null) {
                // todo: send a "server full" message before closing the connection
                Logger.warn("Max clients reached, rejecting connection from {f}", .{address.in});
                return error.ReactorFull; // socket will be closed in the caller
            }
            const client_id = idx.?;
            Logger.info("[{f}] connected as {} (gen {})", .{ address.in, client_id.index, client_id.gen });

            try self.poller.add(socket, client_id.index, true, false);

            const out_message_queue = try self.allocator.create(SPSCQueue(OutMessage));
            out_message_queue.* = try SPSCQueue(OutMessage).init(self.allocator, self.options.client_out_message_queue_size);
            errdefer self.allocator.destroy(out_message_queue);

            const client = ClientConnection.init(
                self.options.max_read_per_tick,
                self.allocator,
                self.job_queue,
                out_message_queue,
                self.input_buffer_pool,
                self.output_buffer_pool,
                self.waker,
                self.poller,
                socket,
                address,
                client_id,
            ) catch |err| {
                Logger.err("failed to initialize client: {}", .{err});
                self.pushIndex(client_id);
                return err;
            };

            self.clients[client_id.index] = client;
            self.connected += 1;
        }

        fn pushIndex(self: *Self, index: ConnectionId) void {
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
        }

        fn popIndex(self: *Self) ?ConnectionId {
            if (self.free_count == 0) {
                return null; // max clients reached
            }

            self.free_count -= 1;
            return self.free_indices[self.free_count];
        }

        fn removeClient(self: *Self, idx: u32) void {
            var client = self.clients[idx];
            self.pushIndex(.{ .index = idx, .gen = client.id.gen + 1 });

            try self.poller.remove(client.socket);
            posix.close(client.socket);
            client.deinit();

            self.connected -= 1;
        }

        const ClientErrorDetails = struct {
            source: []const u8,
            message: []const u8,
        };

        const ClientError = struct {
            message: []const u8,
            details: []const ClientErrorDetails,
            truncated: bool,
        };

        fn sendErrorToClient(self: *Self, client: *ClientConnection, status: http.StatusCode, connection: http.Connection, client_error: ?ClientError) error{ FailedToAcquireBuffer, FailedToWrite, ClientQueueFull }!void {
            // acquire a new output buffer if needed
            if (self.current_output_buffer_idx == null) {
                const buffer_idx = self.output_buffer_pool.acquire() orelse {
                    // no output buffers available
                    Logger.warn("No output buffers available, failed to send response", .{});
                    return error.FailedToAcquireBuffer;
                };

                self.current_output_buffer_idx = buffer_idx;
                self.current_output_buffer = self.output_buffer_pool.buffer(buffer_idx);
            }

            var writer: std.Io.Writer = .fixed(self.current_output_buffer);

            const bytes_written = blk: {
                if (client_error) |c_err| {
                    const response: Response(ClientError) = .{
                        .http = HttpResponse(ClientError).init(
                            status,
                            connection,
                            null,
                            c_err,
                        ),
                    };

                    break :blk ResponseWriter.write(ClientError, response, &writer) catch |err| {
                        Logger.err("Failed to write error response: {}", .{err});
                        // keep the current output buffer to avoid just re-acquiring it in the next iteration
                        return error.FailedToWrite;
                    };
                } else {
                    const response: Response(void) = .{
                        .http = HttpResponse(void).init(
                            status,
                            connection,
                            null,
                            {},
                        ),
                    };

                    break :blk ResponseWriter.write(void, response, &writer) catch |err| {
                        Logger.err("Failed to write error response: {}", .{err});
                        // keep the current output buffer to avoid just re-acquiring it in the next iteration
                        return error.FailedToWrite;
                    };
                }
            };

            const response_data = self.current_output_buffer[0..bytes_written];

            // response_data will be freed by the io thread after sending
            client.enqueueMessage(OutMessage{
                .offset = 0,
                .data = response_data,
                .buffer_idx = self.current_output_buffer_idx.?,
                .keep_alive = true,
            }) catch {
                // client's response queue is full
                // we can't really do anything about it, so just move on to the next job
                // keep the current output buffer to avoid just re-acquiring it in the next iteration
                return error.ClientQueueFull;
            };

            // released in io thread after sending, set to null here to indicate that we don't have a current buffer anymore
            self.current_output_buffer_idx = null;
        }
    };
}
