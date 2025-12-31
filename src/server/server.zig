const std = @import("std");
const posix = std.posix;
const net = std.net;

const ServerOptions = @import("server-options.zig").ServerOptions;
const ClientConnection = @import("client-connection.zig").ClientConnection;
const Job = @import("job.zig").Job;
const Worker = @import("worker.zig").Worker;

const Queue = @import("../utils/mpmc-queue.zig").Queue;

const HandlerFn = @import("../handler-fn/handler-fn.zig").HandlerFn;
const createHandlerFn = @import("../handler-fn/create-handler-fn.zig").createHandlerFn;
const deserializeMessageHeader = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeader;

const ConnectionId = @import("connection-id.zig").ConnectionId;

pub fn Server(comptime options: ServerOptions) type {
    return struct {
        const Self = @This();
        const call_tables = create_call_table(options);

        // creates polls and client slices, and is passed to Client.init and handlers
        allocator: std.mem.Allocator,

        // number connected clients
        connected: usize,

        // polls[0] is always the listening socket
        polls: []posix.pollfd,

        // stack of free connection indices, LIFO
        free_indices: []ConnectionId,

        // number of free indices in free_indices
        free_count: u32,

        // same length as polls[] - 1, maps poll index (client_polls []) to client index (clients [])
        poll_to_client: []u32,

        // list of clients, only client[0..connected] are valid
        clients: []ClientConnection,

        // This is always polls[1..] and it's used to so that we can manipulate
        // clients and client_polls together. Necessary because polls[0] is the
        // listening socket, and we don't ever touch that.
        client_polls: []posix.pollfd,

        jobs_queue: *Queue(Job),

        pub fn init(allocator: std.mem.Allocator) !Self {
            // + 1 for the listening socket
            const polls = try allocator.alloc(posix.pollfd, options.max_clients + 1);
            errdefer allocator.free(polls);

            const clients = try allocator.alloc(ClientConnection, options.max_clients);
            errdefer allocator.free(clients);

            const jobs_buf = try allocator.alloc(Job, 128); //todo: make configurable
            errdefer allocator.free(jobs_buf);

            const job_queue = try allocator.create(Queue(Job));
            job_queue.* = try Queue(Job).init(jobs_buf);

            for (0..8) |i| {
                const worker = try allocator.create(Worker);
                worker.* = try Worker.init(job_queue, call_tables, allocator);

                _ = std.Thread.spawn(.{}, Worker.run, .{worker}) catch |err| {
                    std.debug.print("failed to spawn worker thread {}: {}", .{ i, err });
                    return err;
                };
            }

            var free_indices = try allocator.alloc(ConnectionId, options.max_clients);
            for (0..options.max_clients) |i| {
                free_indices[i] = .{ .index = @intCast(i), .gen = 0 };
            }

            return .{
                .polls = polls,
                .clients = clients,
                .client_polls = polls[1..],
                .poll_to_client = try allocator.alloc(u32, options.max_clients),
                .free_indices = free_indices,
                .free_count = options.max_clients,
                .connected = 0,
                .allocator = allocator,
                .jobs_queue = job_queue,
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

            while (true) {
                // +1 is for the listening socket, -1 timeout means wait indefinitely
                _ = try posix.poll(self.polls[0 .. self.connected + 1], -1);

                if (self.polls[0].revents != 0) {
                    // listening socket is ready, accept new connections
                    self.accept(listener) catch |err| std.debug.print("failed to accept: {}", .{err});
                }

                var i: usize = 0;
                while (i < self.connected) {
                    const revents = self.client_polls[i].revents;
                    if (revents == 0) {
                        // this socket isn't ready, move on to the next one
                        i += 1;
                        continue;
                    }

                    const client_idx = self.poll_to_client[i];
                    var client = &self.clients[client_idx];
                    if (revents & posix.POLL.IN == posix.POLL.IN) {
                        // this socket is ready to be read, keep reading messages until there are no more
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

                            // const heap_msg = try self.allocator.alloc(u8, msg.len);
                            // @memcpy(heap_msg, msg);

                            std.debug.print("got: {any}\n", .{msg});
                            const heap_msg = try self.allocator.alloc(u8, msg.len); // todo: free this somewhere, maybe in worker thread after processing?
                            @memcpy(heap_msg, msg);

                            self.jobs_queue.push(.{ .data = heap_msg, .client_id = client.id });
                        }
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

                std.debug.print("[{f}] connected\n", .{address.in});
                const client_index = self.popIndex();

                const client = ClientConnection.init(self.allocator, socket, address, client_index) catch |err| {
                    posix.close(socket);
                    std.debug.print("failed to initialize client: {}", .{err});
                    self.pushIndex(client_index);
                    return;
                };

                self.clients[client_index.index] = client;

                self.client_polls[self.connected] = .{
                    .fd = socket,
                    .revents = 0,
                    .events = posix.POLL.IN,
                };
                self.poll_to_client[self.connected] = client_index.index;
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
            self.connected = last_index;
        }

        pub fn call(self: *const Self, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
            const header = try deserializeMessageHeader(reader);

            switch (header) {
                .Request => |req_header| {
                    const handler = call_tables[req_header.contract_id][req_header.method_id];
                    try handler(header.Request, self.allocator, reader, writer);
                },
                .Response => {
                    return error.UnexpectedResponseHeader;
                },
            }
        }
    };
}

pub fn create_call_table(comptime options: ServerOptions) []const []const HandlerFn {
    comptime {
        var call_table: []const []const HandlerFn = &.{};
        for (options.contracts) |contract| {
            var handlers: []const HandlerFn = &.{};

            const info = @typeInfo(contract);
            if (info != .@"struct") continue;
            const decls = info.@"struct".decls;

            for (decls) |decl| {
                const fn_name = decl.name;
                const fn_impl = @field(contract, fn_name);

                if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                handlers = handlers ++ @as([]const HandlerFn, &.{createHandlerFn(fn_impl)});
            }
            call_table = call_table ++ @as([]const []const HandlerFn, &.{handlers});
        }

        return call_table;
    }
}
