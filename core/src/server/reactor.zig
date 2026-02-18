const std = @import("std");
const posix = std.posix;

const ClientConnection = @import("client_connection.zig").ClientConnection;
const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const Queue = @import("../utils/spsc_queue.zig").Queue;
const Job = @import("job.zig").Job;
const ConnectionId = @import("connection_id.zig").ConnectionId;
const ServerOptions = @import("server_options.zig").ServerOptions;
const OutMessage = @import("out_message.zig").OutMessage;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const ShutdownState = @import("server.zig").ShutdownState;

const Logger = @import("../logger/logger.zig").Logger.scoped(.reactor);

pub const ReactorHandle = struct {
    wakeup_fd: i32,
    thread: std.Thread,
};

pub const ReactorContext = struct {
    allocator: std.mem.Allocator,
    input_buffer_pool: *BufferPool,
    initiated_by_connection_id: u32,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    wakeup_fd: posix.fd_t,
};

pub fn Reactor(comptime TSchema: type) type {
    const call_table = TSchema.createServerCallTable();

    return struct {
        const Self = @This();

        options: ServerOptions,
        allocator: std.mem.Allocator,

        // number of connected clients
        connected: usize,

        // polls[0] is always the listening socket and polls[1] is always the wakeup socket used by worker threads to notify the reactor thread of completed jobs
        polls: []posix.pollfd,

        // stack of free connection indices, LIFO
        free_indices: []ConnectionId,

        // number of free indices in free_indices
        free_count: u32,

        // same length as polls[] - 2, maps poll index (client_polls []) to client index (clients [])
        poll_to_client: []u32,

        // list of clients, only those with indices in poll_to_client[] are connected
        clients: []ClientConnection,

        // This is always polls[2..] and it's used to so that we can manipulate
        // clients and client_polls together. Necessary because polls[0] is the
        // listening socket, and we don't ever touch that.
        client_polls: []posix.pollfd,

        // number of clients that have messages enqueued to send but haven't been fully sent yet, used to decide when to clear the wakeup fd
        dirty_clients: std.atomic.Value(usize),
        wakeup_fd: posix.fd_t,

        // used by the server to coordinate shutdown between all reactor threads
        shutdown_state: *std.atomic.Value(ShutdownState),

        input_buffer_pool: *BufferPool,
        output_buffer_pool: *BufferPool,

        job_queue: *Queue(Job),

        current_output_buffer: []u8, // only valid if current_output_buffer_idx != null
        current_output_buffer_idx: ?u32,

        pub fn init(
            allocator: std.mem.Allocator,
            address: std.net.Address,
            shutdown_state: *std.atomic.Value(ShutdownState),
            core_id: usize,
            options: ServerOptions,
            ready_count: *std.atomic.Value(u32),
        ) !ReactorHandle {
            const wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

            const thread = try std.Thread.spawn(.{}, startThread, .{
                allocator,
                address,
                shutdown_state,
                wakeup_fd,
                core_id,
                options,
                ready_count,
            });

            return .{
                .wakeup_fd = wakeup_fd,
                .thread = thread,
            };
        }

        fn stop(self: *Self) !void {
            // kick the clients, release their buffers, and close their sockets
            for (0..self.connected) |i| {
                Logger.info("kicked client due to shutdown {} with {} messages in queue", .{ self.poll_to_client[i], self.clients[self.poll_to_client[i]].out_message_queue.count });
                self.removeClient(0);
            }

            posix.close(self.wakeup_fd);

            self.input_buffer_pool.deinit(self.allocator);
            self.allocator.destroy(self.input_buffer_pool);

            self.output_buffer_pool.deinit(self.allocator);
            self.allocator.destroy(self.output_buffer_pool);

            self.allocator.free(self.job_queue.buf);
            self.allocator.destroy(self.job_queue);

            self.allocator.free(self.polls);
            self.allocator.free(self.clients);
            self.allocator.free(self.free_indices);
            self.allocator.free(self.poll_to_client);

            self.allocator.destroy(self);
        }

        fn startThread(
            allocator: std.mem.Allocator,
            address: std.net.Address,
            shutdown_state: *std.atomic.Value(ShutdownState),
            wakeup_fd: posix.fd_t,
            core_id: usize,
            options: ServerOptions,
            ready_count: *std.atomic.Value(u32),
        ) !void {
            const linux = std.os.linux;
            var mask: [16]u64 = .{0} ** 16;

            const idx = core_id / 64;
            const bit = core_id % 64;

            mask[idx] |= @as(usize, @intCast(1)) << @as(u6, @intCast(bit));

            const tid = linux.gettid();

            try linux.sched_setaffinity(
                tid,
                &mask,
            );

            // + 2 for the listening socket and the wakeup socket
            const polls = try allocator.alloc(posix.pollfd, options.max_clients + 2);
            errdefer allocator.free(polls);

            const clients = try allocator.alloc(ClientConnection, options.max_clients);
            errdefer allocator.free(clients);

            const jobs_buf = try allocator.alloc(Job, options.max_jobs_in_queue);
            errdefer allocator.free(jobs_buf);

            const job_queue = try allocator.create(Queue(Job));
            job_queue.* = try Queue(Job).init(jobs_buf);
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

            const poll_to_client = try allocator.alloc(u32, options.max_clients);
            errdefer allocator.free(poll_to_client);

            // no workers for now, todo: add Task<T> or DefferedResult<T> as a tag for contract methods that should be executed on worker threads and then add workers back in
            // const workers = try allocator.alloc(Worker, options.worker_threads);

            const self = try allocator.create(Self);
            self.* = Self{
                .options = options,
                .allocator = allocator,

                .clients = clients,
                .client_polls = polls[2..],
                .poll_to_client = poll_to_client,
                .free_indices = free_indices,
                .free_count = options.max_clients,
                .connected = 0,

                .job_queue = job_queue,

                .polls = polls,
                .dirty_clients = std.atomic.Value(usize).init(0),

                .wakeup_fd = wakeup_fd,
                .shutdown_state = shutdown_state,

                .input_buffer_pool = input_buffer_pool,
                .output_buffer_pool = output_buffer_pool,

                .current_output_buffer = undefined,
                .current_output_buffer_idx = null,
            };

            try self.run(address, ready_count);
        }

        fn run(self: *Self, address: std.net.Address, ready_count: *std.atomic.Value(u32)) !void {
            Logger.debug("run reactor thread {}", .{std.Thread.getCurrentId()});

            const socket_type: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
            const protocol = posix.IPPROTO.TCP;
            const listener = try posix.socket(address.any.family, socket_type, protocol);
            defer posix.close(listener);

            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(listener, &address.any, address.getOsSockLen());
            try posix.listen(listener, 128);

            // first polling slot is reserved for the listening socket
            self.polls[0] = .{
                .fd = listener,
                .revents = 0,
                .events = posix.POLL.IN,
            };

            // second polling slot is reserved for the wakeup fd
            self.polls[1] = .{
                .fd = self.wakeup_fd,
                .revents = 0,
                .events = posix.POLL.IN,
            };

            _ = ready_count.fetchAdd(1, .release);

            while (true) {
                // +2 is for the listening socket and the wakeup fd, infinite/no timeout
                _ = try posix.poll(self.polls[0 .. self.connected + 2], -1);

                if (self.shutdown_state.load(.acquire) == .immediate) break;

                // new connections
                if (self.polls[0].revents != 0) {
                    // listening socket is ready, accept new connections
                    self.accept(listener) catch |err| Logger.err("failed to accept: {}", .{err});
                }

                // wakeup fd is ready
                const wakeup_ready = self.polls[1].revents != 0;

                // has to be a while loop instead of a for loop because we may remove clients in the middle of iterating using swap remove which would require us to not increment i
                var i: usize = 0;
                while (i < self.connected) {
                    const client_idx = self.poll_to_client[i];
                    var client = &self.clients[client_idx];

                    //#region in: messages from clients
                    const revents = self.client_polls[i].revents;
                    if (revents != 0) {
                        if (revents & posix.POLL.IN == posix.POLL.IN) {
                            // this socket is ready to be read, fairness is implemented in client.readMessage()
                            client.readMessage() catch |err| {
                                switch (err) {
                                    error.Closed, error.ConnectionResetByPeer => {
                                        Logger.info("[{f} | {}/{}] disconnected", .{ client.address.in, client_idx, client.id.gen });
                                    },
                                    else => {
                                        Logger.err("Error reading from client {}: {}", .{ client_idx, err });
                                    },
                                }

                                // removeClient will swap the last client into position i, do not increment i
                                self.removeClient(i);
                                continue; // move on to the next client
                            };
                        } else {
                            Logger.warn("Found unexpected event ({}) in socket for client {}", .{ revents, client.id.index });
                        }
                    }
                    //#endregion

                    if (wakeup_ready) {
                        //#region out: responses and broadcasts
                        const latest_out_message = client.out_message_queue.tryPeek();

                        // has messages queued to send
                        if (latest_out_message) |out| {
                            const data = switch (out.data) {
                                .single => |single| single.data,
                                .shared => |shared| shared.get(),
                            };

                            var sent: usize = 0;
                            while (out.offset < data.len and sent < self.options.max_write_per_tick) {
                                const n = posix.write(client.socket, data[out.offset..]) catch |err| switch (err) {
                                    error.NotOpenForWriting, error.WouldBlock => break,
                                    else => return err,
                                };

                                if (n == 0) break; // socket closed?

                                sent += n;
                                out.offset += n;
                            }

                            if (out.offset >= data.len) {
                                // message fully sent, remove it from the queue
                                _ = client.out_message_queue.tryPop();

                                switch (out.data) {
                                    .single => |single| self.output_buffer_pool.release(single.buffer_idx),
                                    .shared => |shared| shared.release(),
                                }
                            }

                            if (client.out_message_queue.isEmpty()) {
                                if (client.dirty.swap(false, .acq_rel)) {
                                    // no more messages left to send to this client
                                    _ = self.dirty_clients.fetchSub(1, .release);
                                }
                            }
                        }
                        //#endregion
                    }

                    i += 1;
                }

                //#region handlers: handle non blocking jobs
                while (self.job_queue.tryPeek()) |job| {
                    // input buffer will be released in handler right after deserialization or in the first point of failure

                    var reader: std.Io.Reader = .fixed(job.data);
                    const headers = deserializeMessageHeaders(&reader) catch |err| {
                        // invalid message, release the buffer and move on to the next job. No need to send an error response since we can't even be sure if the client sent a valid request or not
                        _ = self.job_queue.tryPop();
                        self.input_buffer_pool.release(job.buffer_idx);

                        Logger.warn("Failed to deserialize message headers: {}", .{err});
                        continue;
                    };

                    if (headers != .Request) return error.UnexpectedMessageHeader;
                    const req_header = headers.Request;

                    const client = &self.clients[job.client_id.index];
                    if (client.id.gen != job.client_id.gen) {
                        // job was meant for a previous generation of the client, just release the buffer there is no point in processing it
                        _ = self.job_queue.tryPop();
                        self.input_buffer_pool.release(job.buffer_idx);

                        Logger.info("Client gen mismatch: expected {}, got {}", .{ client.id.gen, job.client_id.gen });
                        continue;
                    }

                    // acquire a new output buffer
                    if (self.current_output_buffer_idx == null) {
                        const buffer_idx = self.output_buffer_pool.acquire() orelse {
                            // no output buffers available, can't process any jobs yet. Don't consume anything
                            break;
                        };

                        self.current_output_buffer_idx = buffer_idx;
                        self.current_output_buffer = self.output_buffer_pool.buffer(buffer_idx);
                    }

                    const handler = call_table[req_header.contract_id][req_header.method_id];

                    var writer: std.Io.Writer = .fixed(self.current_output_buffer);
                    handler(
                        ReactorContext{
                            .allocator = self.allocator,
                            .input_buffer_pool = self.input_buffer_pool,
                            .initiated_by_connection_id = job.client_id.index,
                            .client_connections = self.clients[0..self.connected],
                            .connected_clients = self.poll_to_client[0..self.connected],
                            .wakeup_fd = self.wakeup_fd,
                        },
                        headers.Request,
                        &reader,
                        &writer,
                        job.buffer_idx,
                    ) catch |err| {
                        // handlers release the input buffer regardless of success or failure, so we don't need to release it here, just pop the job to consume it
                        // keep the current output buffer avoid just re-acquiring it in the next iteration
                        _ = self.job_queue.tryPop();

                        Logger.warn("Handler failed with error: {}", .{err});
                        continue;
                    };

                    const response_payload_len = std.mem.readInt(u32, self.current_output_buffer[MessageHeadersByteSize.Response - 4 .. MessageHeadersByteSize.Response], .big);
                    const response_data = self.current_output_buffer[0 .. MessageHeadersByteSize.Response + response_payload_len];

                    // response_data will be freed by the reactor thread after sending
                    client.enqueueMessage(OutMessage{
                        .offset = 0,
                        .data = .{
                            .single = .{
                                .data = response_data,
                                .buffer_idx = self.current_output_buffer_idx.?,
                            },
                        },
                    }) catch |err| {
                        // either the client's response is full or we failed to wake up the reactor
                        // in either case we can't really do anything about it, so just consume the job, input buffer was released in the handler
                        // keep the current output buffer avoid just re-acquiring it in the next iteration
                        _ = self.job_queue.tryPop();

                        Logger.debug("Failed to enqueue message: {}", .{err});
                        continue;
                    };

                    _ = self.job_queue.tryPop(); // consume the job after successfully enqueuing the message
                    self.current_output_buffer_idx = null; // released in reactor thread, set to null here to indicate that we don't have a current buffer anymore
                }
                //#endregion

                // nothing left to send, clear the eventfd
                if (self.dirty_clients.load(.acquire) == 0)
                    try self.drain_wakeup_fd();
            }

            try self.stop();
        }

        fn accept(self: *Self, listener: posix.socket_t) !void {
            // the while loop will keep accepting connections until the first time posix.accept tries to block in order to wait for a new connection, i.e. there are no more pending connections
            while (true) {
                var address: std.net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(std.net.Address);
                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return err,
                };

                const idx = self.popIndex();
                if (idx == null) {
                    posix.close(socket); // todo: send a "server full" message before closing the connection
                    Logger.warn("Max clients reached, rejecting connection from {f}", .{address.in});
                    return;
                }
                const client_id = idx.?;
                Logger.info("[{f}] connected as {} (gen {})", .{ address.in, client_id.index, client_id.gen });

                const out_message_buf = try self.allocator.alloc(OutMessage, self.options.client_out_message_queue_size);
                errdefer self.allocator.free(out_message_buf);

                const out_message_queue = try self.allocator.create(Queue(OutMessage));
                out_message_queue.* = try Queue(OutMessage).init(out_message_buf);
                errdefer self.allocator.destroy(out_message_queue);

                const client = ClientConnection.init(
                    self.options.max_read_per_tick,
                    self.allocator,
                    self.job_queue,
                    out_message_queue,
                    self.input_buffer_pool,
                    self.output_buffer_pool,
                    &self.dirty_clients,
                    self.wakeup_fd,
                    socket,
                    address,
                    client_id,
                ) catch |err| {
                    posix.close(socket);
                    Logger.err("failed to initialize client: {}", .{err});
                    self.pushIndex(client_id);
                    return;
                };

                self.clients[client_id.index] = client;

                self.client_polls[self.connected] = .{
                    .fd = socket,
                    .revents = 0,
                    .events = posix.POLL.IN,
                };
                self.poll_to_client[self.connected] = client_id.index;
                self.connected += 1;
            }
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

        fn removeClient(self: *Self, at: usize) void {
            const client_idx = self.poll_to_client[at];
            var client = self.clients[client_idx];
            self.pushIndex(.{ .index = client_idx, .gen = client.id.gen + 1 });

            posix.close(client.socket);
            client.deinit();

            const last_index = self.connected - 1;
            self.client_polls[at] = self.client_polls[last_index];
            self.poll_to_client[at] = self.poll_to_client[last_index];
            self.connected = last_index;
        }

        fn drain_wakeup_fd(self: *Self) !void {
            var buf: [8]u8 = undefined;
            while (true) {
                _ = posix.read(self.wakeup_fd, &buf) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return err,
                };
            }
        }
    };
}
