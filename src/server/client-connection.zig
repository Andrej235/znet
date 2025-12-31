const std = @import("std");
const posix = std.posix;

const deserializeMessageHeaders = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;
const ConnectionId = @import("connection-id.zig").ConnectionId;

pub const ClientConnection = struct {
    reader: ConnectionReader,
    socket: posix.socket_t,
    address: std.net.Address,
    id: ConnectionId,

    pub fn init(
        allocator: std.mem.Allocator,
        socket: posix.socket_t,
        address: std.net.Address,
        id: ConnectionId,
    ) !ClientConnection {
        const reader = try ConnectionReader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        return .{
            .reader = reader,
            .socket = socket,
            .address = address,
            .id = id,
        };
    }

    pub fn deinit(self: *const ClientConnection, allocator: std.mem.Allocator) void {
        self.reader.deinit(allocator);
    }

    pub fn readMessage(self: *ClientConnection) !?[]const u8 {
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

    fn init(allocator: std.mem.Allocator, size: usize) !ConnectionReader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .buffer = buf,
            .reader = std.Io.Reader.fixed(buf),
        };
    }

    fn deinit(self: *const ConnectionReader, allocator: std.mem.Allocator) void {
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
