const std = @import("std");
const posix = std.posix;

const Client = @import("client.zig").ClientInterface;

const Queue = @import("../utils/spsc_queue.zig").Queue;
const Job = @import("./inbound_message.zig").InboundMessage;

const MessageReadResult = @import("./message_read_result.zig").MessageReadResult;
const ConnectionReader = @import("./connection_reader.zig").ConnectionReader;

const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const Waker = @import("../waker/waker.zig");
const Poller = @import("../poller/poller.zig");

const Logger = @import("../logger/logger.zig").Logger.scoped(.server_connection);

pub const ServerConnection = struct {
    allocator: std.mem.Allocator,

    connection_socket: posix.socket_t,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    client: *Client,
    connection_reader: ConnectionReader,

    waker: Waker,
    poller: Poller,

    network_thread: std.Thread = undefined,

    pub fn init(allocator: std.mem.Allocator, client: *Client) !ServerConnection {
        const poller = try Poller.init(allocator, 2);

        return ServerConnection{
            .allocator = allocator,
            .connection_socket = undefined,
            .client = client,
            .connection_reader = ConnectionReader.init(allocator, client),

            .poller = poller,
            .waker = undefined,
        };
    }

    pub fn deinit(self: *ServerConnection) void {
        self.connection_reader.deinit();
        self.poller.deinit();
    }

    pub fn connect(self: *ServerConnection, address: std.net.Address) ConnectError!void {
        self.connection_socket = posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        ) catch |err| {
            var buff: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(buff[0..], "Failed to obtain socket: {}", .{err}) catch unreachable;
            @panic(msg);
        };

        self.waker = Waker.init() catch |err| {
            var buff: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(buff[0..], "Failed to initialize waker: {}", .{err}) catch unreachable;
            @panic(msg);
        };

        self.poller.add(self.connection_socket, 0, true, false) catch |err| {
            var buff: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(buff[0..], "Failed to add socket to poller: {}", .{err}) catch unreachable;
            @panic(msg);
        };

        self.waker.register(&self.poller, 1) catch |err| {
            var buff: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(buff[0..], "Failed to register waker with poller: {}", .{err}) catch unreachable;
            @panic(msg);
        };

        posix.connect(self.connection_socket, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {},
            error.ConnectionRefused, error.ConnectionResetByPeer => return ConnectError.ConnectionRefused,
            else => @panic(std.fmt.allocPrint(self.allocator, "Failed to connect to server: {}", .{err}) catch unreachable),
        };

        self.connected.store(true, .release);

        self.network_thread = std.Thread.spawn(.{}, networkThread, .{self}) catch return ConnectError.FailedToSpawnThread;
    }

    pub fn disconnect(self: *ServerConnection) !void {
        self.connected.store(false, .release);
        self.waker.wake() catch {
            Logger.err("Failed to wake up the network thread during disconnect", .{});
        };

        self.network_thread.join();

        posix.close(self.connection_socket);
        self.waker.deinit();
    }

    fn forceDisconnectNoWait(self: *ServerConnection) void {
        self.connected.store(false, .release);
        self.waker.wake() catch {
            Logger.err("Failed to wake up the network thread during force disconnect", .{});
        };

        posix.close(self.connection_socket);
        self.waker.deinit(); // todo: this is probably a bug? closing the waker before the network thread has a chance to clean up will likely cause issues
    }

    pub fn readMessage(self: *ServerConnection) !?MessageReadResult {
        return self.connection_reader.readMessage(self.connection_socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.Closed, error.ConnectionResetByPeer => return error.Closed,
            else => return err,
        };
    }

    fn networkThread(self: *ServerConnection) !void {
        while (true) event_loop: {
            var it = self.poller.wait(-1);

            while (it.next()) |event| {
                if (event.index == 0 and event.in) { // server sent a message or closed the connection
                    // process inbound messages, resolve pending requests
                    const msg = self.readMessage() catch |err| {
                        if (err == error.Closed) {
                            Logger.info("Connection closed by peer", .{});

                            self.forceDisconnectNoWait();
                            try self.client.pending_requests_map.clear();
                            break :event_loop;
                        } else {
                            Logger.err("Error reading message: {}", .{err});
                            continue;
                        }
                    };

                    if (msg) |in_msg| {
                        var reader = std.io.Reader.fixed(in_msg.data);
                        const headers = try deserializeMessageHeaders(&reader);

                        switch (headers) {
                            .Request => {
                                Logger.err("Unexpected Request message found in inbound queue", .{});
                                return;
                            },
                            .Response => |response| {
                                const pending_request = self.client.pending_requests_map.get(response.request_id) catch {
                                    Logger.err("No pending request found for request_id: {d}", .{response.request_id});
                                    continue;
                                };

                                pending_request.resolve(in_msg.data, in_msg.buffer_idx);
                            },
                            .Broadcast => |broadcast| {
                                Logger.debug("broadcast", .{});
                                _ = broadcast; // todo: implement broadcast handling on workers when enabled
                                return error.Unimplemented;
                            },
                        }
                    }
                }

                if (event.index == 1 and event.in) { // waker was signaled, either a new outbound message is available or the connection is being closed by the consumer
                    if (!self.connected.load(.acquire)) break :event_loop;

                    // send outbound messages
                    while (self.client.outbound_queue.tryPop()) |out_msg| {
                        defer self.client.outbound_buffer_pool.release(out_msg.buffer_idx);

                        const total_len = out_msg.data.len;
                        var sent: usize = 0;

                        while (sent < total_len) {
                            sent += try posix.send(self.connection_socket, out_msg.data[sent..total_len], 0);
                        }
                    }

                    // clear the wakeup event
                    try self.waker.drain();
                }
            }
        }
    }

    pub const ConnectError = error{
        ConnectionRefused,
        FailedToSpawnThread,
        PollFailed,
    };
};
