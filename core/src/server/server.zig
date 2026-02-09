const std = @import("std");
const posix = std.posix;
const net = std.net;

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;

const ServerOptions = @import("server_options.zig").ServerOptions;
const ClientConnection = @import("client_connection.zig").ClientConnection;
const Worker = @import("worker.zig").Worker;

const Queue = @import("../utils/mpmc_queue.zig").Queue;
const Job = @import("job.zig").Job;
const OutMessage = @import("out_message.zig").OutMessage;

const HandlerFn = @import("handler_fn/handler_fn.zig").HandlerFn;
const createHandlerFn = @import("handler_fn/create_handler_fn.zig").createHandlerFn;

const ConnectionId = @import("connection_id.zig").ConnectionId;

pub const Server = struct {
    pub const call_table = createCallTable();

    options: ServerOptions,
    workers: []Worker,

    // creates polls and client slices, and is passed to Client.init and handlers
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
    stop_flag: std.atomic.Value(bool),

    input_buffer_pool: *BufferPool,

    job_queue: *Queue(Job),

    pub fn init(allocator: std.mem.Allocator, comptime options: ServerOptions) !*Server {
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

        const wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

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

        const poll_to_client = try allocator.alloc(u32, options.max_clients);
        errdefer allocator.free(poll_to_client);

        const workers = try allocator.alloc(Worker, options.worker_threads);

        const self: *Server = try allocator.create(Server);
        self.* = .{
            .options = options,
            .allocator = allocator,
            .workers = workers,

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
            .stop_flag = std.atomic.Value(bool).init(false),

            .input_buffer_pool = input_buffer_pool,
        };

        for (0..options.worker_threads) |i| {
            workers[i] = try Worker.init(options.job_result_buffer_size, self);

            workers[i].runThread() catch |err| {
                std.debug.print("Failed to spawn worker thread {}: {}", .{ i, err });
                return err;
            };
        }

        return self;
    }

    pub fn deinit(self: *Server) !void {
        try self.stop();
        posix.close(self.wakeup_fd);

        self.job_queue.close();

        for (self.workers) |*w| {
            w.thread.join();
            w.deinit();
        }
        self.allocator.free(self.workers);

        self.input_buffer_pool.deinit(self.allocator);
        self.allocator.destroy(self.input_buffer_pool);

        self.allocator.free(self.job_queue.buf);
        self.allocator.destroy(self.job_queue);

        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
        self.allocator.free(self.free_indices);
        self.allocator.free(self.poll_to_client);

        self.allocator.destroy(self);
    }

    pub fn run(self: *Server, address: std.net.Address) !void {
        const socket_type: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, socket_type, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
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

        while (true) {
            // +2 is for the listening socket and the wakeup fd, infinite/no timeout
            _ = try posix.poll(self.polls[0 .. self.connected + 2], -1);

            if (self.stop_flag.load(.acquire)) break;

            // new connections
            if (self.polls[0].revents != 0) {
                // listening socket is ready, accept new connections
                self.accept(listener) catch |err| std.debug.print("failed to accept: {}", .{err});
            }

            // wakeup fd is ready, at least one worker thread has completed a job and enqueued a message to send to a client
            const has_out = self.polls[1].revents != 0;

            // has to be a while loop instead of a for loop because we may remove clients in the middle of iterating using swap remove which would require us to not increment i
            var i: usize = 0;
            while (i < self.connected) {
                const client_idx = self.poll_to_client[i];
                var client = &self.clients[client_idx];

                //#region in: messages from clients
                const revents = self.client_polls[i].revents;
                if (revents != 0) {
                    if (revents & posix.POLL.IN == posix.POLL.IN) {
                        // this socket is ready to be read, keep reading messages until there are no more
                        // client.readMessage() implements fairness
                        while (true) {
                            client.readMessage() catch |err| {
                                if (err == error.Closed)
                                    std.debug.print("[{f} | {}/{}] disconnected\n", .{ client.address.in, client_idx, client.id.gen })
                                else
                                    std.debug.print("Error reading from client {}: {}\n", .{ client_idx, err });

                                // removeClient will swap the last client into position i, do not increment i
                                self.removeClient(i);
                                break;
                            };

                            // no more messages, but this client is still connected
                            i += 1;
                            break;
                        }
                    } else {
                        std.debug.print("Found unexpected event ({}) in socket for client {}\n", .{ revents, client.id.index });
                    }
                }
                //#endregion

                //#region out: responses and broadcasts
                if (has_out) {
                    const latest_out_message = client.out_message_queue.tryPeek();

                    // has messages queued to send
                    if (latest_out_message) |out| {
                        const data = switch (out.data) {
                            .single => |single| single,
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
                                .single => |single| self.allocator.free(single),
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
                }
                //#endregion

                i += 1;
            }

            // nothing left to send, clear the eventfd
            if (self.dirty_clients.load(.acquire) == 0)
                try self.drain_wakeup_fd();
        }

        for (0..self.connected) |i| {
            std.debug.print("kicked client due to shutdown {} with {} messages in queue\n", .{ self.poll_to_client[i], self.clients[self.poll_to_client[i]].out_message_queue.count });
            self.removeClient(0);
        }
    }

    fn drain_wakeup_fd(self: *Server) !void {
        var buf: [8]u8 = undefined;
        while (true) {
            _ = posix.read(self.wakeup_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }
    }

    pub fn stop(self: *Server) !void {
        self.stop_flag.store(true, .release);
        _ = try posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        // the while loop will keep accepting connections until the first time posix.accept tries to block in order to wait for a new connection, i.e. there are no more pending connections
        while (true) {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client_id = self.popIndex();
            std.debug.print("[{f}] connected as {} (gen {})\n", .{ address.in, client_id.index, client_id.gen });

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
                self,
                socket,
                address,
                client_id,
            ) catch |err| {
                posix.close(socket);
                std.debug.print("failed to initialize client: {}", .{err});
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

    fn pushIndex(self: *Server, index: ConnectionId) void {
        self.free_indices[self.free_count] = index;
        self.free_count += 1;
    }

    fn popIndex(self: *Server) ConnectionId {
        if (self.free_count == 0) {
            // this should never happen because we limit the number of clients to max_clients
            @branchHint(.cold);
            @panic("no free connection indices");
        }

        self.free_count -= 1;
        return self.free_indices[self.free_count];
    }

    fn removeClient(self: *Server, at: usize) void {
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
};

pub fn createCallTable() []const []const HandlerFn {
    comptime {
        var call_table: []const []const HandlerFn = &.{};
        for (@import("znet_contract_registry").server_contracts) |TContract| {
            var handlers: []const HandlerFn = &.{};

            const info = @typeInfo(TContract);
            if (info != .@"struct") continue;
            const decls = info.@"struct".decls;

            for (decls) |decl| {
                const fn_name = decl.name;
                const fn_impl = @field(TContract, fn_name);

                if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                handlers = handlers ++ @as([]const HandlerFn, &.{createHandlerFn(fn_impl)});
            }
            call_table = call_table ++ @as([]const []const HandlerFn, &.{handlers});
        }

        return call_table;
    }
}
