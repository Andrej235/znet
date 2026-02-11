const std = @import("std");
const posix = std.posix;

const Client = @import("client.zig").Client;

const Queue = @import("../utils//mpmc_queue.zig").Queue;
const Job = @import("./inbound_message.zig").InboundMessage;

const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const MessageHeaders = @import("../message_headers/message_headers.zig").MessageHeaders;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

pub const ServerConnection = struct {
    allocator: std.mem.Allocator,
    job_queue: *Queue(Job),

    connection_socket: posix.socket_t,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    client: *Client,
    connection_reader: ConnectionReader,

    pub fn init(allocator: std.mem.Allocator, client: *Client) ServerConnection {
        return ServerConnection{
            .allocator = allocator,
            .job_queue = client.inbound_queue,
            .connection_socket = undefined,
            .client = client,
            .connection_reader = ConnectionReader.init(allocator, client),
        };
    }
    pub fn deinit() void {}

    pub fn connect() !void {}
    pub fn disconnect() void {}

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
};

const ConnectionReader = struct {
    allocator: std.mem.Allocator,
    connection_socket: posix.socket_t,

    current_buffer: []u8, // only valid if current_buffer_idx != null
    current_buffer_idx: ?u32,
    pos: usize,

    current_headers: ?MessageHeaders,

    client: *Client,

    fn init(allocator: std.mem.Allocator, client: *Client) ConnectionReader {
        return .{
            .allocator = allocator,
            .connection_socket = undefined,

            .current_buffer = undefined,
            .current_buffer_idx = null,
            .pos = 0,

            .current_headers = null,

            .client = client,
        };
    }

    fn deinit(self: *const ConnectionReader) void {
        if (self.current_buffer_idx) |idx| {
            self.client.input_buffer_pool.release(idx);
        }
    }

    const MessageReadResult = struct {
        buffer_idx: u32,
        data: []const u8,
    };

    fn readMessage(self: *ConnectionReader, socket: posix.socket_t) !?MessageReadResult {
        if (self.current_buffer_idx == null) {
            const idx = self.client.input_buffer_pool.acquire() orelse return null;
            self.current_buffer_idx = idx;
            self.current_buffer = self.client.input_buffer_pool.buffer(idx);

            self.pos = 0;
            self.current_headers = null;
        }

        while (true) {
            // loop until we have a full message to process
            if (try self.tryParseMessage()) |msg|
                return msg;

            // read more data from the socket, fills up the buffer from pos to the end
            const n = try posix.read(socket, self.current_buffer[self.pos..]);

            if (n == 0) // no more data, connection closed or EOF
                return error.Closed;

            self.pos += n;
        }
    }

    inline fn tryParseMessage(self: *ConnectionReader) !?MessageReadResult {
        if (self.current_headers == null) {
            var reader = std.io.Reader.fixed(self.current_buffer);

            if (self.pos < MessageHeadersByteSize.Request) {
                // not enough data to read the header
                return null;
            }

            self.current_headers = (try deserializeMessageHeaders(&reader));
        }

        const payload_len = switch (self.current_headers.?) {
            .Request => return error.InvalidState, // we should never have request headers in the connection reader, they are only used for outgoing messages
            .Response => |res| res.payload_len,
            .Broadcast => |b| b.payload_len,
        };
        const message_len = payload_len + MessageHeadersByteSize.Response; // response and broadcast headers have the same size

        if (self.pos < message_len) {
            // not enough data to read the full message
            return null;
        }

        if (self.pos < message_len) {
            // not enough data to read the full message
            return null;
        }

        const msg = self.current_buffer[0..message_len];
        const current_buffer_idx = self.current_buffer_idx.?;

        if (self.pos == message_len) {
            self.current_buffer_idx = null;
            return .{
                .buffer_idx = current_buffer_idx,
                .data = msg,
            };
        }

        const remaining_bytes = self.current_buffer[message_len..self.pos];
        // if there isn't a free buffer, we can't process this message yet
        // we also can't return the fully read one because then we wouldn't be able to preserve the remaining data for the next read
        const new_buffer_idx = self.client.input_buffer_pool.acquire() orelse return null;
        const new_buffer = self.client.input_buffer_pool.buffer(new_buffer_idx);

        // move the remaining bytes to the new buffer so that we can continue reading that message in this new buffer we just acquired from the pool
        @memcpy(new_buffer[0..remaining_bytes.len], remaining_bytes);

        self.current_buffer_idx = new_buffer_idx;
        self.current_buffer = new_buffer;

        self.pos -= message_len;
        self.current_headers = null;

        return .{
            .buffer_idx = current_buffer_idx,
            .data = msg,
        };
    }
};
