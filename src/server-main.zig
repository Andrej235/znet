const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const RequestHeaders = @import("message-headers/request-header.zig").RequestHeaders;
const deserializeMessageHeaders = @import("message-headers/deserialize-message-header.zig").deserializeMessageHeaders;

const log = std.log.scoped(.tcp_demo);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, 4096);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try server.run(address);
}

const Server = struct {
    // creates polls and client slices, and is passed to Client.init for it to create its read buffer
    allocator: Allocator,

    // number connected clients
    connected: usize,

    // polls[0] is always the listening socket
    polls: []posix.pollfd,

    // list of clients, only client[0..connected] are valid
    clients: []ClientConnection,

    // This is always polls[1..] and it's used to so that we can manipulate
    // clients and client_polls together. Necessary because polls[0] is the
    // listening socket, and we don't ever touch that.
    client_polls: []posix.pollfd,

    fn init(allocator: Allocator, max_clients: usize) !Server {
        // + 1 for the listening socket
        const polls = try allocator.alloc(posix.pollfd, max_clients + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(ClientConnection, max_clients);
        errdefer allocator.free(clients);

        return .{
            .polls = polls,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Server) void {
        // TODO: Close connected sockets?
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
    }

    fn run(self: *Server, address: std.net.Address) !void {
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
                self.accept(listener) catch |err| log.err("failed to accept: {}", .{err});
            }

            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    // this socket isn't ready, move on to the next one
                    i += 1;
                    continue;
                }

                var client = &self.clients[i];
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

                        std.debug.print("got: {any}\n", .{msg});
                    }
                }
            }
        }
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

            std.debug.print("[{f}] connected\n", .{address.in});
            const client = ClientConnection.init(self.allocator, socket, address) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };

            self.clients[self.connected] = client;
            self.client_polls[self.connected] = .{
                .fd = socket,
                .revents = 0,
                .events = posix.POLL.IN,
            };
            self.connected += 1;
        }
    }

    fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];

        posix.close(client.socket);
        client.deinit(self.allocator);

        // replace the removed client with the last connected client
        // technically the client still exists in the array with an invalid socket but since 'connected' is decremented it will be ignored
        // it will be truly removed when the next client connects and overwrites it
        const last_index = self.connected - 1;
        self.clients[at] = self.clients[last_index];
        self.client_polls[at] = self.client_polls[last_index];

        self.connected = last_index;
    }
};

const ClientConnection = struct {
    reader: ConnectionReader,
    socket: posix.socket_t,
    address: std.net.Address,

    fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address) !ClientConnection {
        const reader = try ConnectionReader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        return .{
            .reader = reader,
            .socket = socket,
            .address = address,
        };
    }

    fn deinit(self: *const ClientConnection, allocator: Allocator) void {
        self.reader.deinit(allocator);
    }

    fn readMessage(self: *ClientConnection) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.Closed => {
                std.debug.print("[{f}] disconnected\n", .{self.address.in});
                return error.Closed;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return err;
            },
        };
    }
};

const header_size = 14;

const ConnectionReader = struct {
    buffer: []u8,
    reader: std.Io.Reader,
    pos: usize = 0,

    fn init(allocator: Allocator, size: usize) !ConnectionReader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .buffer = buf,
            .reader = std.Io.Reader.fixed(buf),
        };
    }

    fn deinit(self: *const ConnectionReader, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    fn readMessage(self: *ConnectionReader, socket: posix.socket_t) ![]u8 {
        while (true) {
            // loop until we have a full message to process
            if (try self.bufferedMessage()) |msg|
                return msg;

            // read more data from the socket, fills up the buffer from pos to the end
            const n = try posix.read(socket, self.buffer[self.pos..]);
            if (n == 0) // no more data, connection closed or EOF
                return error.Closed;

            self.pos += n;
        }
    }

    fn bufferedMessage(self: *ConnectionReader) !?[]u8 {
        if (self.pos < header_size) {
            // not enough data to read the header
            return null;
        }

        const header = try deserializeMessageHeaders(&self.reader);
        const payload_len = header.Request.payload_len;

        const message_len = payload_len + header_size;

        if (self.pos < message_len) {
            // not enough data to read the full message
            return null;
        }

        // copy out the full message before shifting the buffer
        const msg = self.buffer[0..message_len];

        // shift remaining data to the front of the buffer
        @memmove(self.buffer[0 .. self.pos - message_len], self.buffer[message_len..self.pos]);
        self.pos -= message_len;
        self.reader.seek = 0;

        return msg;
    }
};
