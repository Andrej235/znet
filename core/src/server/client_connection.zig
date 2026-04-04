const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;
const ConnectionId = @import("connection_id.zig").ConnectionId;
const RequestHeaders = @import("../message_headers/request_headers.zig").RequestHeaders;

const Queue = @import("../queues/spsc_queue.zig").Queue;
const Job = @import("./job.zig").Job;
const OutMessage = @import("./out_message.zig").OutMessage;
const Logger = @import("../logger/logger.zig").Logger.scoped(.client_connection);

const Parser = @import("./parsers/parser.zig").Parser;

const Waker = @import("../waker/waker.zig");
const Poller = @import("../poller/poller.zig");

pub const ClientConnection = struct {
    allocator: std.mem.Allocator,
    job_queue: *Queue(Job),
    out_message_queue: *Queue(OutMessage),

    waker: Waker,
    poller: Poller,

    output_buffer_pool: *BufferPool,

    reader: ConnectionReader,
    socket: posix.socket_t,
    address: std.net.Address,
    id: ConnectionId,

    pub fn init(
        max_read_per_tick: usize,
        allocator: std.mem.Allocator,
        job_queue: *Queue(Job),
        out_message_queue: *Queue(OutMessage),
        input_buffer_pool: *BufferPool,
        output_buffer_pool: *BufferPool,
        waker: Waker,
        poller: Poller,
        socket: posix.socket_t,
        address: std.net.Address,
        id: ConnectionId,
    ) !ClientConnection {
        const reader = ConnectionReader.init(allocator, input_buffer_pool, max_read_per_tick, id);
        errdefer reader.deinit(allocator);

        return .{
            .reader = reader,
            .socket = socket,
            .id = id,
            .address = address,
            .allocator = allocator,
            .job_queue = job_queue,
            .output_buffer_pool = output_buffer_pool,
            .out_message_queue = out_message_queue,
            .poller = poller,
            .waker = waker,
        };
    }

    pub fn deinit(self: *const ClientConnection) void {
        while (self.out_message_queue.tryPop()) |msg| {
            switch (msg.data) {
                .single => |single| self.output_buffer_pool.release(single.buffer_idx),
                .shared => |shared| shared.release(),
            }
        }

        self.reader.deinit();

        self.out_message_queue.deinit(self.allocator);
        self.allocator.destroy(self.out_message_queue);
    }

    pub fn readMessage(self: *ClientConnection) !void {
        const msg = try self.reader.readMessage(self.socket) orelse return;

        try self.job_queue.tryPush(.{
            .data = msg.data,
            .buffer_idx = msg.buffer_idx,
            .client_id = self.id,
        });

        // wake up the reactor thread to process this new job
        try self.waker.wake();
    }

    pub fn enqueueMessage(self: *ClientConnection, msg: OutMessage) !void {
        const was_empty = self.out_message_queue.isEmpty();
        if (!was_empty) return;

        self.out_message_queue.tryPush(msg) catch |err| {
            Logger.warn("Failed to enqueue message for client {d}: {}", .{ self.id.index, err });
            return err;
        };

        try self.poller.modify(self.socket, self.id.index, true, true);
    }
};

pub const ConnectionReader = struct {
    allocator: std.mem.Allocator,
    connection_id: ConnectionId,
    max_read_per_tick: usize,

    current_buffer: []u8, // only valid if current_buffer_idx != null
    current_buffer_idx: ?u32,
    buffered_bytes: usize,

    current_headers: ?RequestHeaders,

    input_buffer_pool: *BufferPool,

    parser: ?Parser,

    fn init(allocator: std.mem.Allocator, input_buffer_pool: *BufferPool, max_read_per_tick: usize, connection_id: ConnectionId) ConnectionReader {
        return .{
            .allocator = allocator,
            .connection_id = connection_id,
            .max_read_per_tick = max_read_per_tick,
            .current_buffer = undefined,
            .current_buffer_idx = null,
            .buffered_bytes = 0,
            .current_headers = null,
            .input_buffer_pool = input_buffer_pool,
            .parser = null,
        };
    }

    fn deinit(self: *const ConnectionReader) void {
        if (self.current_buffer_idx) |idx| {
            self.input_buffer_pool.release(idx);
        }
    }

    pub const MessageReadResult = struct {
        buffer_idx: u32,
        data: []const u8,
    };

    fn readMessage(self: *ConnectionReader, socket: posix.socket_t) !?MessageReadResult {
        if (self.current_buffer_idx == null) {
            const idx = self.input_buffer_pool.acquire() orelse return null;
            self.current_buffer_idx = idx;
            self.current_buffer = self.input_buffer_pool.buffer(idx);

            self.buffered_bytes = 0;
            self.current_headers = null;
        }

        var reads: usize = 0;
        while (reads < self.max_read_per_tick) {
            // read more data from the socket, fills up the buffer from pos to the end
            const n = posix.recv(socket, self.current_buffer[self.buffered_bytes..], 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };

            if (n == 0) // no more data, connection closed or EOF
                return error.Closed;

            reads += n;
            self.buffered_bytes += n;

            if (self.parser == null) {
                // if we don't have a parser yet, try to determine the protocol and get the appropriate parser
                self.parser = self.tryGetParser() orelse continue;
            }

            // try to parse a message from the buffered data
            if (try self.parser.?.parse(self)) |msg| {
                return msg;
            }
        }

        return null;
    }

    fn tryGetParser(self: *ConnectionReader) ?Parser {
        if (self.buffered_bytes == 0) {
            // nothing to parse
            return null;
        }

        const buf = self.current_buffer[0..self.buffered_bytes];

        if (buf[0] == 0x16) {
            // TLS ClientHello
            return Parser{ .tls = .init() };
        }

        if (std.ascii.isUpper(buf[0]) and std.ascii.isUpper(buf[1]) and std.ascii.isUpper(buf[2]) and std.mem.indexOfScalar(u8, buf, ' ') != null) {
            // likely http 1.1
            return Parser{ .http1 = .init() };
        }

        return null;
    }

    // not used, todo: implement custom protocol for znet messages
    fn tryParseZnetMessage(self: *ConnectionReader) !?MessageReadResult {
        if (self.current_headers == null) {
            var reader = std.io.Reader.fixed(self.current_buffer);

            if (self.buffered_bytes < MessageHeadersByteSize.Request) {
                // not enough data to read the header
                return null;
            }

            const headers = try deserializeMessageHeaders(&reader);
            self.current_headers = headers.Request;
        }

        const payload_len = self.current_headers.?.payload_len;
        const message_len = payload_len + MessageHeadersByteSize.Request;

        if (self.buffered_bytes < message_len) {
            // not enough data to read the full message
            return null;
        }

        const msg = self.current_buffer[0..message_len];
        const current_buffer_idx = self.current_buffer_idx.?;

        if (self.buffered_bytes == message_len) {
            self.current_buffer_idx = null;
            return .{
                .buffer_idx = current_buffer_idx,
                .data = msg,
            };
        }

        const remaining_bytes = self.current_buffer[message_len..self.buffered_bytes];
        // if there isn't a free buffer, we can't process this message yet
        // we also can't return the fully read one because then we wouldn't be able to preserve the remaining data for the next read
        const new_buffer_idx = self.input_buffer_pool.acquire() orelse return null;
        const new_buffer = self.input_buffer_pool.buffer(new_buffer_idx);

        // move the remaining bytes to the new buffer so that we can continue reading that message in this new buffer we just acquired from the pool
        @memcpy(new_buffer[0..remaining_bytes.len], remaining_bytes);

        self.current_buffer_idx = new_buffer_idx;
        self.current_buffer = new_buffer;

        self.buffered_bytes -= message_len;
        self.current_headers = null;

        return .{
            .buffer_idx = current_buffer_idx,
            .data = msg,
        };
    }
};
