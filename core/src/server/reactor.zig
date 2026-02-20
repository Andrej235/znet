const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

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

const Listener = @import("../listener/listener.zig");
const Waker = @import("../waker/waker.zig");

const Logger = @import("../logger/logger.zig").Logger.scoped(.reactor);

pub const ReactorHandle = struct {
    waker: Waker,
    thread: std.Thread,
};

pub const ReactorContext = struct {
    allocator: std.mem.Allocator,
    input_buffer_pool: *BufferPool,
    initiated_by_connection_id: u32,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    waker: Waker,
};

pub fn Reactor(comptime TSchema: type) type {
    const call_table = TSchema.createServerCallTable();

    return struct {
        const Self = @This();

        options: ServerOptions,
        allocator: std.mem.Allocator,

        // number of connected clients
        connected: usize,

        // max_clients + 2 for the listening socket and the wakeup socket
        // listening socket has index max_clients, wakeup socket has index max_clients + 1, the rest are clients
        epoll_events: []linux.epoll_event,

        // stack of free connection indices, LIFO
        free_indices: []ConnectionId,

        // number of free indices in free_indices
        free_count: u32,

        // list of clients, only those with indices in epoll_to_client[] are connected
        clients: []ClientConnection,

        waker: Waker,

        // used by the server to coordinate shutdown between all reactor threads
        shutdown_state: *std.atomic.Value(ShutdownState),

        input_buffer_pool: *BufferPool,
        output_buffer_pool: *BufferPool,

        job_queue: *Queue(Job),

        current_output_buffer: []u8, // only valid if current_output_buffer_idx != null
        current_output_buffer_idx: ?u32,

        epoll_fd: i32,

        pub fn init(
            allocator: std.mem.Allocator,
            address: std.net.Address,
            shutdown_state: *std.atomic.Value(ShutdownState),
            io_thread_id: usize,
            options: ServerOptions,
            ready_count: *std.atomic.Value(u32),
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
                Logger.info("kicked client due to shutdown {} with {} messages in queue", .{ self.epoll_to_client[i], self.clients[self.epoll_to_client[i]].out_message_queue.count });
                self.removeClient(0);
            }

            self.waker.deinit();

            self.input_buffer_pool.deinit(self.allocator);
            self.allocator.destroy(self.input_buffer_pool);

            self.output_buffer_pool.deinit(self.allocator);
            self.allocator.destroy(self.output_buffer_pool);

            self.allocator.free(self.job_queue.buf);
            self.allocator.destroy(self.job_queue);

            self.allocator.free(self.epoll_events);
            self.allocator.free(self.clients);
            self.allocator.free(self.free_indices);
            self.allocator.free(self.epoll_to_client);

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
        ) !void {
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

            // + 2 for the listening socket and the wakeup socket
            const epoll_events = try allocator.alloc(linux.epoll_event, options.max_clients + 2);
            for (epoll_events) |*e| {
                e.* = .{
                    .data = .{ .fd = -1 },
                    .events = 0,
                };
            }
            errdefer allocator.free(epoll_events);

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

            const epoll_fd = linux.epoll_create();

            // no workers for now, todo: add Task<T> or DefferedResult<T> as a tag for contract methods that should be executed on worker threads and then add workers back in
            // const workers = try allocator.alloc(Worker, options.worker_threads);

            const self = try allocator.create(Self);
            self.* = Self{
                .options = options,
                .allocator = allocator,

                .clients = clients,
                .free_indices = free_indices,
                .free_count = options.max_clients,
                .connected = 0,

                .job_queue = job_queue,

                .epoll_events = epoll_events,

                .waker = waker,
                .shutdown_state = shutdown_state,

                .input_buffer_pool = input_buffer_pool,
                .output_buffer_pool = output_buffer_pool,

                .current_output_buffer = undefined,
                .current_output_buffer_idx = null,

                .epoll_fd = @intCast(epoll_fd),
            };

            try self.run(address, ready_count);
        }

        fn run(self: *Self, address: std.net.Address, ready_reactors_count: *std.atomic.Value(u32)) !void {
            var listener = try Listener.init(address);
            defer listener.deinit();

            // first polling slot is reserved for the listening socket
            var listener_event: linux.epoll_event = .{
                .data = .{
                    .u32 = self.options.max_clients,
                },
                .events = linux.EPOLL.IN,
            };
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, listener.impl.listener_fd, &listener_event);

            // second polling slot is reserved for the wakeup fd
            var wakeup_event: linux.epoll_event = .{
                .data = .{
                    .u32 = self.options.max_clients + 1,
                },
                .events = linux.EPOLL.IN,
            };
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.waker.impl.wakeup_fd, &wakeup_event);

            // signal to the server that this reactor thread is ready to accept connections and process jobs
            // this is used to coordinate the startup of multiple reactor threads
            _ = ready_reactors_count.fetchAdd(1, .release);

            while (true) {
                // +2 is for the listening socket and the wakeup fd, infinite/no timeout
                const ready_count = linux.epoll_wait(self.epoll_fd, self.epoll_events.ptr, @intCast(self.connected + 2), -1);

                for (self.epoll_events[0..ready_count]) |event| {
                    const events = event.events;
                    if (events == 0) continue;
                    const idx = event.data.u32;

                    if (idx == self.options.max_clients) { // listening socket
                        // listening socket is ready, accept new connections
                        try listener.drainAccepts(TSchema, self);
                        continue;
                    }

                    if (idx == self.options.max_clients + 1) { // wakeup fd
                        // either the server shutdown or there are new jobs to process

                        if (self.shutdown_state.load(.acquire) == .immediate) break;

                        // handle non blocking jobs
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
                                    .connected_clients = &.{},
                                    .waker = self.waker,
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
                            }) catch {
                                // client's response queue is full
                                // we can't really do anything about it, so just consume the job, input buffer was released in the handler
                                // keep the current output buffer avoid just re-acquiring it in the next iteration
                                _ = self.job_queue.tryPop();
                                continue;
                            };

                            _ = self.job_queue.tryPop(); // consume the job after successfully enqueuing the message
                            self.current_output_buffer_idx = null; // released in reactor thread, set to null here to indicate that we don't have a current buffer anymore
                        }

                        // nothing left to send, clear the eventfd
                        if (self.job_queue.isEmpty())
                            try self.waker.drain();

                        continue;
                    }

                    // client
                    const client_idx = idx;
                    var client = &self.clients[client_idx];

                    if (events & linux.EPOLL.IN == linux.EPOLL.IN) {
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
                            self.removeClient(client_idx);
                            continue; // move on to the next client
                        };
                    }

                    if (events & linux.EPOLL.OUT == linux.EPOLL.OUT) {
                        // has messages to send and can accept being written to
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
                                // no more messages left to send to this client
                                var event_listener = linux.epoll_event{
                                    .events = linux.EPOLL.IN,
                                    .data = .{
                                        .u32 = client_idx,
                                    },
                                };
                                _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, client.socket, &event_listener);
                            }
                        }
                    }
                }
            }

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

            var epoll_event: linux.epoll_event = .{
                .data = .{ .u32 = client_id.index },
                .events = linux.EPOLL.IN,
            };
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, socket, &epoll_event);

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
                self.waker,
                self.epoll_fd,
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

            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, client.socket, null);
            posix.close(client.socket);
            client.deinit();

            self.connected -= 1;
        }
    };
}
