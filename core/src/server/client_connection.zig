const std = @import("std");
const posix = std.posix;

const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;
const ConnectionId = @import("connection_id.zig").ConnectionId;
const RequestHeaders = @import("../message_headers/request_headers.zig").RequestHeaders;

const Queue = @import("../utils/mpmc_queue.zig").Queue;
const Job = @import("./job.zig").Job;
const OutMessage = @import("./out_message.zig").OutMessage;

pub const ClientConnection = struct {
    allocator: std.mem.Allocator,
    job_queue: *Queue(Job),
    out_message_queue: *Queue(OutMessage),

    reader: ConnectionReader,
    socket: posix.socket_t,
    address: std.net.Address,
    id: ConnectionId,

    pub fn init(
        read_buffer_size: usize,
        max_read_per_tick: usize,
        allocator: std.mem.Allocator,
        job_queue: *Queue(Job),
        out_message_queue: *Queue(OutMessage),
        socket: posix.socket_t,
        address: std.net.Address,
        id: ConnectionId,
    ) !ClientConnection {
        const reader = try ConnectionReader.init(allocator, max_read_per_tick, read_buffer_size, id);
        errdefer reader.deinit(allocator);

        return .{
            .reader = reader,
            .socket = socket,
            .id = id,
            .address = address,
            .allocator = allocator,
            .job_queue = job_queue,
            .out_message_queue = out_message_queue,
        };
    }

    pub fn deinit(self: *const ClientConnection, allocator: std.mem.Allocator) void {
        self.reader.deinit(allocator);
        self.allocator.free(self.out_message_queue.buf);
        self.allocator.destroy(self.out_message_queue);
    }

    pub fn readMessage(self: *ClientConnection) !void {
        const msg = self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock, error.NotOpenForReading => return,
            else => return err,
        } orelse return;

        self.job_queue.push(.{ .data = msg, .client_id = self.id });
    }
};

const ConnectionReader = struct {
    allocator: std.mem.Allocator,
    connection_id: ConnectionId,
    max_read_per_tick: usize,
    buffer: []u8,
    reader: std.Io.Reader,
    pos: usize = 0,
    headers: ?RequestHeaders = null,

    fn init(allocator: std.mem.Allocator, max_read_per_tick: usize, size: usize, connection_id: ConnectionId) !ConnectionReader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .max_read_per_tick = max_read_per_tick,
            .buffer = buf,
            .reader = std.Io.Reader.fixed(buf),
            .connection_id = connection_id,
            .allocator = allocator,
        };
    }

    fn deinit(self: *const ConnectionReader, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    fn readMessage(self: *ConnectionReader, socket: posix.socket_t) !?[]u8 {
        var reads: usize = 0;
        while (reads < self.max_read_per_tick) {
            // loop until we have a full message to process
            if (try self.bufferedMessage()) |msg|
                return msg;

            // read more data from the socket, fills up the buffer from pos to the end
            const n = try posix.read(socket, self.buffer[self.pos..]);

            if (n == 0) // no more data, connection closed or EOF
            {
                @branchHint(.cold);
                return error.Closed;
            }

            reads += n;
            self.pos += n;
        }

        return null;
    }

    inline fn bufferedMessage(self: *ConnectionReader) !?[]u8 {
        if (self.headers == null) {
            if (self.pos < MessageHeadersByteSize.Request) {
                // not enough data to read the header
                return null;
            }

            self.reader.seek = 0;
            self.headers = (try deserializeMessageHeaders(&self.reader)).Request;
        }

        const payload_len = self.headers.?.payload_len;
        const message_len = payload_len + MessageHeadersByteSize.Request;

        if (self.pos < message_len) {
            // not enough data to read the full message
            return null;
        }

        const msg = self.buffer[0..message_len];
        // todo: replace with a ring buffer for zero-copy and no allocations
        // freed in worker thread after processing
        const heap_msg = try self.allocator.alloc(u8, msg.len);
        @memcpy(heap_msg, msg);

        // shift remaining data to the front of the buffer
        @memmove(self.buffer[0 .. self.pos - message_len], self.buffer[message_len..self.pos]);
        self.pos -= message_len;
        self.reader.seek = 0;

        self.headers = null;
        return heap_msg;
    }
};
