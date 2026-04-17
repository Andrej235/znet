const std = @import("std");
const posix = std.posix;
const http = @import("../http/http.zig");

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;
const ConnectionId = @import("connection_id.zig").ConnectionId;
const Request = @import("../requests/request.zig").Request;
const RequestHeaders = @import("../message_headers/request_headers.zig").RequestHeaders;

const Parser = @import("./parsers/parser.zig").Parser;

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

    pub fn init(allocator: std.mem.Allocator, input_buffer_pool: *BufferPool, max_read_per_tick: usize, connection_id: ConnectionId) ConnectionReader {
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

    pub fn deinit(self: *const ConnectionReader) void {
        if (self.current_buffer_idx) |idx| {
            self.input_buffer_pool.release(idx);
        }
    }

    const MessageReadResult = struct {
        buffer_idx: u32,
        request: Request,
    };

    pub fn readMessage(self: *ConnectionReader, socket: posix.socket_t) !?MessageReadResult {
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
                self.parser = self.tryGetParser() orelse return error.UnsupportedProtocol;
            }

            // try to parse a message from the buffered data
            // todo:? free input buffer if parser fails to parse the message (e.g. if it's an invalid http request)
            if (try self.parser.?.parse(self)) |parse_result| {
                const buffer_idx = try self.passBufferOwnership(parse_result.consumed_bytes);

                return MessageReadResult{
                    .buffer_idx = buffer_idx,
                    .request = parse_result.request,
                };
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

        // http1 detection
        const first_line_end_idx = std.mem.indexOfScalar(u8, buf, '\n');
        if (first_line_end_idx) |end_idx| http1: {
            if (buf[end_idx - 1] != '\r') {
                // http1 requests must have CRLF line endings
                break :http1;
            }

            if (std.mem.indexOf(u8, buf[0 .. end_idx - 1], "HTTP")) |http_idx| {
                const version_str = buf[http_idx .. end_idx - 1];
                const version = http.Version.fromString(version_str);
                if (version == null)
                    return null;

                switch (version.?) {
                    .http10, .http11 => return Parser{ .http1 = .init() },
                    .http2 => return null, // not implemented
                }
            }
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
                .request = msg,
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
            .request = msg,
        };
    }

    fn passBufferOwnership(self: *ConnectionReader, bytes: usize) !u32 {
        if (self.current_buffer_idx == null) {
            return error.NoBufferAvailable;
        }

        if (bytes > self.buffered_bytes) {
            return error.NotEnoughData;
        }

        const idx = self.current_buffer_idx.?;

        if (bytes == self.buffered_bytes) {
            self.current_buffer_idx = null;
            return idx;
        }

        const remaining_bytes = self.current_buffer[bytes..self.buffered_bytes];
        // if there isn't a free buffer, we can't process this message yet
        // we also can't return the fully read one because then we wouldn't be able to preserve the remaining data for the next read
        const new_buffer_idx = self.input_buffer_pool.acquire() orelse return error.NoBufferAvailable;
        const new_buffer = self.input_buffer_pool.buffer(new_buffer_idx);

        // move the remaining bytes to the new buffer so that we can continue reading that message in this new buffer we just acquired from the pool
        @memcpy(new_buffer[0..remaining_bytes.len], remaining_bytes);

        self.current_buffer_idx = new_buffer_idx;
        self.current_buffer = new_buffer;

        self.buffered_bytes -= bytes;

        return idx;
    }
};
