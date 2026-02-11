const std = @import("std");
const posix = std.posix;

const Client = @import("client.zig").Client;

const Queue = @import("../utils//mpmc_queue.zig").Queue;
const Job = @import("./inbound_message.zig").InboundMessage;

const MessageReadResult = @import("./message_read_result.zig").MessageReadResult;
const ConnectionReader = @import("./connection_reader.zig").ConnectionReader;

const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;

pub const ServerConnection = struct {
    allocator: std.mem.Allocator,
    job_queue: *Queue(Job),

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
            .job_queue = client.inbound_queue,
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

    pub fn connect(self: *ServerConnection, address: std.net.Address) !void {
        self.connection_socket = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );

        self.wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

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

        _ = try posix.poll(self.polls, -1);
        while (true) {
            posix.connect(self.connection_socket, &address.any, address.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            break;
        }

        self.connected.store(true, .release);

        self.network_thread = try std.Thread.spawn(.{}, networkThread, .{self});
    }

    pub fn disconnect(self: *ServerConnection) !void {
        self.connected.store(false, .release);
        _ = try posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));

        self.network_thread.join();

        posix.close(self.connection_socket);
        posix.close(self.wakeup_fd);
    }

    pub fn readMessage(self: *ServerConnection) !void {
        const msg = self.connection_reader.readMessage(self.connection_socket) catch |err| switch (err) {
            error.WouldBlock, error.NotOpenForReading => return,
            else => return err,
        } orelse return;

        try self.job_queue.push(.{
            .data = msg.data,
            .buffer_idx = msg.buffer_idx,
        });
    }

    fn networkThread(self: *ServerConnection) !void {
        while (true) {
            _ = try posix.poll(self.polls, -1);
            if (!self.connected.load(.acquire)) break;

            // process inbound messages
            if (self.polls[0].revents & posix.POLL.IN == posix.POLL.IN) {
                self.readMessage() catch |err| {
                    std.debug.print("Error reading message from server: {}\n", .{err});
                };
            }

            // process outbound messages
            if (self.polls[1].revents != 0) {
                while (self.client.outbound_queue.tryPop()) |out_msg| {
                    var writer: std.io.Writer = .fixed(self.client.send_buffer);
                    const headers = try out_msg.serialize(out_msg, &writer);
                    switch (headers) {
                        .Request => |req_headers| {
                            const total_len = req_headers.payload_len + MessageHeadersByteSize.Request;

                            var sent: usize = 0;
                            while (sent < total_len) {
                                sent += try posix.write(self.connection_socket, self.client.send_buffer[sent..total_len]);
                            }
                        },
                        .Response => {
                            std.debug.print("Tried to read response in outbound messages, client\n", .{});
                        },
                        .Broadcast => {
                            std.debug.print("Tried to read broadcast in outbound messages, client\n", .{});
                        },
                    }
                }

                // clear the wakeup event
                var buf: u64 = 0;
                _ = try std.posix.read(self.wakeup_fd, std.mem.asBytes(&buf));
            }
        }
    }
};
