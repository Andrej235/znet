const std = @import("std");
const posix = std.posix;

const Client = @import("client.zig").ClientInterface;

const Queue = @import("../utils/spsc_queue.zig").Queue;
const Job = @import("./inbound_message.zig").InboundMessage;

const MessageReadResult = @import("./message_read_result.zig").MessageReadResult;
const ConnectionReader = @import("./connection_reader.zig").ConnectionReader;

const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

pub const ServerConnection = struct {
    allocator: std.mem.Allocator,

    connection_socket: posix.socket_t,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    client: *Client,
    connection_reader: ConnectionReader,

    // 0 is server, 1 is wakeup fd
    polls: []posix.pollfd,
    wakeup_fd: posix.fd_t,

    network_thread: std.Thread = undefined,

    pub fn init(allocator: std.mem.Allocator, client: *Client) !ServerConnection {
        const polls = try allocator.alloc(posix.pollfd, 2);

        return ServerConnection{
            .allocator = allocator,
            .connection_socket = undefined,
            .client = client,
            .connection_reader = ConnectionReader.init(allocator, client),

            .polls = polls,
            .wakeup_fd = undefined,
        };
    }

    pub fn deinit(self: *ServerConnection) void {
        self.connection_reader.deinit();

        self.allocator.free(self.polls);
    }

    pub fn connect(self: *ServerConnection, address: std.net.Address) ConnectError!void {
        self.connection_socket = posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        ) catch |err|
            @panic(std.fmt.allocPrint(self.allocator, "Failed to obtain socket: {}", .{err}) catch unreachable);

        self.wakeup_fd = posix.eventfd(0, posix.SOCK.NONBLOCK) catch |err|
            @panic(std.fmt.allocPrint(self.allocator, "Failed to obtain wakeup fd: {}", .{err}) catch unreachable);

        self.polls[0] = .{
            .fd = self.connection_socket,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        self.polls[1] = .{
            .fd = self.wakeup_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        _ = posix.poll(self.polls, -1) catch return ConnectError.PollFailed;
        while (true) {
            posix.connect(self.connection_socket, &address.any, address.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionRefused, error.ConnectionResetByPeer => return ConnectError.ConnectionRefused,
                else => @panic(std.fmt.allocPrint(self.allocator, "Failed to connect to server: {}", .{err}) catch unreachable),
            };
            break;
        }

        self.connected.store(true, .release);

        self.network_thread = std.Thread.spawn(.{}, networkThread, .{self}) catch return ConnectError.FailedToSpawnThread;
    }

    pub fn disconnect(self: *ServerConnection) !void {
        self.connected.store(false, .release);
        _ = try posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));

        self.network_thread.join();

        posix.close(self.connection_socket);
        posix.close(self.wakeup_fd);
    }

    fn forceDisconnectNoWait(self: *ServerConnection) void {
        self.connected.store(false, .release);
        _ = posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1))) catch {};

        posix.close(self.connection_socket);
        posix.close(self.wakeup_fd);
    }

    pub fn readMessage(self: *ServerConnection) !?MessageReadResult {
        return self.connection_reader.readMessage(self.connection_socket) catch |err| switch (err) {
            error.WouldBlock, error.NotOpenForReading => return null,
            error.Closed, error.ConnectionResetByPeer => return error.Closed,
            else => return err,
        };
    }

    fn networkThread(self: *ServerConnection) !void {
        while (true) {
            _ = try posix.poll(self.polls, -1);
            if (!self.connected.load(.acquire)) break;

            if (self.polls[0].revents & posix.POLL.IN == posix.POLL.IN) {
                // process inbound messages, resolve pending requests
                const msg = self.readMessage() catch |err| {
                    if (err == error.Closed) {
                        std.debug.print("Connection closed by peer\n", .{});

                        self.forceDisconnectNoWait();
                        try self.client.pending_requests_map.clear();
                        break;
                    } else {
                        std.debug.print("Error reading message: {}\n", .{err});
                        continue;
                    }
                };

                if (msg) |in_msg| {
                    var reader = std.io.Reader.fixed(in_msg.data);
                    const headers = try deserializeMessageHeaders(&reader);

                    switch (headers) {
                        .Request => {
                            std.debug.print("Unexpected Request message found in inbound queue\n", .{});
                            return;
                        },
                        .Response => |response| {
                            const pending_request = self.client.pending_requests_map.get(response.request_id) catch {
                                std.debug.print("No pending request found for request_id: {d}\n", .{response.request_id});
                                continue;
                            };

                            pending_request.resolve(in_msg.data, in_msg.buffer_idx);
                        },
                        .Broadcast => |broadcast| {
                            std.debug.print("broadcast\n", .{});
                            _ = broadcast; // todo: implement broadcast handling on workers when enabled
                            return error.Unimplemented;
                        },
                    }
                }
            }

            // process messages
            if (self.polls[1].revents != 0) {
                // send outbound messages
                while (self.client.outbound_queue.tryPop()) |out_msg| {
                    defer self.client.outbound_buffer_pool.release(out_msg.buffer_idx);

                    const total_len = out_msg.data.len;
                    var sent: usize = 0;

                    while (sent < total_len) {
                        sent += try posix.write(self.connection_socket, out_msg.data[sent..total_len]);
                    }
                }

                // clear the wakeup event
                var buf: u64 = 0;
                _ = try posix.read(self.wakeup_fd, std.mem.asBytes(&buf));
            }
        }
    }

    pub const ConnectError = error{
        ConnectionRefused,
        FailedToSpawnThread,
        PollFailed,
    };
};
