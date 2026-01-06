const std = @import("std");
const posix = std.posix;
const net = std.net;

const ServerOptions = @import("server-options.zig").ServerOptions;
const ClientConnection = @import("client-connection.zig").ClientConnection;
const Job = @import("job.zig").Job;
const Worker = @import("worker.zig").Worker;
const JobResult = @import("job-result.zig").JobResult;
const Queue = @import("../utils/mpmc-queue.zig").Queue;

const HandlerFn = @import("handler-fn/handler-fn.zig").HandlerFn;
const createHandlerFn = @import("handler-fn/create-handler-fn.zig").createHandlerFn;

const ConnectionId = @import("connection-id.zig").ConnectionId;

pub fn Server(comptime options: ServerOptions) type {
    return struct {
        const Self = @This();
        const call_tables = createCallTable(options);

        // creates polls and client slices, and is passed to Client.init and handlers
        allocator: std.mem.Allocator,

        // number connected clients
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

        wakeup_fd: posix.fd_t,

        job_queue: *Queue(Job),
        job_result_queue: *Queue(JobResult),

        pub fn init(allocator: std.mem.Allocator) !Self {
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

            const job_results_buf = try allocator.alloc(JobResult, options.max_jobs_in_queue);
            errdefer allocator.free(job_results_buf);

            const job_result_queue = try allocator.create(Queue(JobResult));
            job_result_queue.* = try Queue(JobResult).init(job_results_buf);

            const wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

            for (0..options.worker_threads) |i| {
                const worker = try allocator.create(Worker);
                worker.* = try Worker.init(
                    options.job_result_buffer_size,
                    job_queue,
                    job_result_queue,
                    call_tables,
                    wakeup_fd,
                    allocator,
                );

                _ = std.Thread.spawn(.{}, Worker.run, .{worker}) catch |err| {
                    std.debug.print("failed to spawn worker thread {}: {}", .{ i, err });
                    return err;
                };
            }

            var free_indices = try allocator.alloc(ConnectionId, options.max_clients);
            errdefer allocator.free(free_indices);
            for (0..options.max_clients) |i| {
                free_indices[i] = .{ .index = @intCast(i), .gen = 0 };
            }

            const poll_to_client = try allocator.alloc(u32, options.max_clients);
            errdefer allocator.free(poll_to_client);

            return .{
                .polls = polls,
                .clients = clients,
                .client_polls = polls[2..],
                .poll_to_client = poll_to_client,
                .free_indices = free_indices,
                .free_count = options.max_clients,
                .connected = 0,
                .allocator = allocator,
                .job_queue = job_queue,
                .job_result_queue = job_result_queue,
                .wakeup_fd = wakeup_fd,
            };
        }

        pub fn run(self: *Self, address: std.net.Address) !noreturn {
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

            self.polls[1] = .{
                .fd = self.wakeup_fd,
                .revents = 0,
                .events = posix.POLL.IN,
            };

            while (true) {
                // +2 is for the listening socket and the wakeup socket, -1 timeout means wait indefinitely
                _ = try posix.poll(self.polls[0 .. self.connected + 2], -1);

                // new connections
                if (self.polls[0].revents != 0) {
                    // listening socket is ready, accept new connections
                    self.accept(listener) catch |err| std.debug.print("failed to accept: {}", .{err});
                }

                // read requests from clients
                var i: usize = 0;
                while (i < self.connected) {
                    const revents = self.client_polls[i].revents;
                    if (revents == 0) {
                        // this socket isn't ready, move on to the next one
                        i += 1;
                        continue;
                    }

                    if (revents & posix.POLL.IN == posix.POLL.IN) {
                        const client_idx = self.poll_to_client[i];
                        var client = &self.clients[client_idx];

                        // this socket is ready to be read, keep reading messages until there are no more
                        // todo: implement round robin to avoid one client/request blocking the entire i/o loop
                        while (true) {
                            const msg = client.readMessage() catch {
                                // removeClient will swap the last client into position i, do not increment i
                                self.removeClient(i);
                                break;
                            } orelse {
                                // no more messages, but this client is still connected
                                i += 1;
                                break;
                            };

                            // freed in worker thread after processing
                            const heap_msg = try self.allocator.alloc(u8, msg.len);
                            @memcpy(heap_msg, msg);

                            self.job_queue.push(.{ .data = heap_msg, .client_id = client.id });
                        }
                    } else {
                        std.debug.print("Client ready for out\n", .{});
                        continue;
                    }
                }

                // send responses to clients
                if (self.polls[1].revents != 0) {
                    // wakeup socket is ready, read the eventfd to clear it
                    var buf: [8]u8 = undefined;
                    _ = try posix.read(self.wakeup_fd, &buf);

                    // process all available job results
                    while (self.job_result_queue.tryPop()) |job_result| {
                        defer self.allocator.free(job_result.data);

                        const client_idx = job_result.client_id.index;
                        const client = &self.clients[client_idx];
                        if (client.id.gen != job_result.client_id.gen)
                            continue; // client has disconnected and a new client has taken its place, drop the response

                        // todo: implement round robin or similar to avoid one client starving others, maybe change polling to watch out for POLLOUT on clients with pending responses
                        var sent: usize = 0;
                        while (sent < job_result.data.len) {
                            sent += posix.write(client.socket, job_result.data[sent..]) catch |err| switch (err) {
                                error.NotOpenForWriting => break,
                                else => return err,
                            };
                        }

                        std.debug.print("---> response sent to {} (gen {}): {any}\n", .{ job_result.client_id.index, job_result.client_id.gen, job_result.data });
                    }
                }
            }
        }

        fn accept(self: *Self, listener: posix.socket_t) !void {
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

                const client = ClientConnection.init(options.client_read_buffer_size, self.allocator, socket, address, client_id) catch |err| {
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

        fn pushIndex(self: *Self, index: ConnectionId) void {
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
        }

        fn popIndex(self: *Self) ConnectionId {
            if (self.free_count == 0) {
                // this should never happen because we limit the number of clients to max_clients
                @branchHint(.cold);
                @panic("no free connection indices");
            }

            self.free_count -= 1;
            return self.free_indices[self.free_count];
        }

        fn removeClient(self: *Self, at: usize) void {
            const client_idx = self.poll_to_client[at];
            var client = self.clients[client_idx];
            self.pushIndex(.{ .index = client_idx, .gen = client.id.gen + 1 });

            posix.close(client.socket);
            client.deinit(self.allocator);

            const last_index = self.connected - 1;
            self.client_polls[at] = self.client_polls[last_index];
            self.poll_to_client[at] = self.poll_to_client[last_index];
            self.connected = last_index;
        }
    };
}

pub fn createCallTable(comptime options: ServerOptions) []const []const HandlerFn {
    comptime {
        var call_table: []const []const HandlerFn = &.{};
        for (options.contracts) |TContract| {
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
