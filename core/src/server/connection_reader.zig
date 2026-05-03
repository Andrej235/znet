const std = @import("std");
const posix = std.posix;
const http = @import("../http/http.zig");

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const ConnectionId = @import("connection_id.zig").ConnectionId;
const Request = @import("../requests/request.zig").Request;
const RequestValidationError = @import("./validation_errors/request_validation_error.zig").RequestValidationError;

const Parser = @import("./parsers/parser.zig").Parser;
const Http1Parser = @import("./parsers/http1.zig").Http1Parser;

pub const ConnectionReader = struct {
    allocator: std.mem.Allocator,
    connection_id: ConnectionId,
    max_read_per_tick: usize,

    current_buffer: []u8, // only valid if current_buffer_idx != null
    current_buffer_idx: ?u32,
    buffered_bytes: usize,

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
            .input_buffer_pool = input_buffer_pool,
            .parser = null,
        };
    }

    pub fn deinit(self: *const ConnectionReader) void {
        if (self.current_buffer_idx) |idx| {
            self.input_buffer_pool.release(idx);
        }
    }

    const MessageReadResult = union(enum) {
        success: struct {
            buffer_idx: u32,
            request: Request,
        },
        parser_error: struct {
            keep_alive: bool,
            validation_error: RequestValidationError,
        },
        unrecoverable_parser_error: ?RequestValidationError,
    };

    pub fn readMessage(self: *ConnectionReader, socket: posix.socket_t) !?MessageReadResult {
        if (self.current_buffer_idx == null) {
            const idx = self.input_buffer_pool.acquire() orelse return null;
            self.current_buffer_idx = idx;
            self.current_buffer = self.input_buffer_pool.buffer(idx);

            self.buffered_bytes = 0;
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
            const parser_result = self.parser.?.parse(self);
            switch (parser_result) {
                .needs_more_data => continue, // need to read more data before we can parse a full message, continue reading from the socket

                .success => |res| {
                    // input buffer will be released after the message is processed on the thread that processed it (either io or worker thread)
                    const buffer_idx = try self.passBufferOwnership(res.consumed_bytes);

                    return MessageReadResult{
                        .success = .{
                            .buffer_idx = buffer_idx,
                            .request = res.request,
                        },
                    };
                },

                .err => |err| {
                    // in case of an error that can be safely recovered from (e.g. an unsupported http method or content type)
                    // we must preserve any additional data that may be in the buffer after the parsed message so that we can continue parsing subsequent messages

                    if (err.consumed_bytes == self.buffered_bytes) {
                        self.buffered_bytes = 0;
                    } else {
                        const remaining_bytes = self.current_buffer[err.consumed_bytes..self.buffered_bytes];

                        // move the remaining bytes to the start of current buffer so that we can continue reading that message
                        // there is no need to preserve data from the request that caused the error because the parser should not have created any new slices from said request
                        @memmove(self.current_buffer[0..remaining_bytes.len], remaining_bytes);
                        self.buffered_bytes -= err.consumed_bytes;
                    }

                    return MessageReadResult{
                        .parser_error = .{
                            .keep_alive = err.keep_alive,
                            .validation_error = err.validation_error,
                        },
                    };
                },

                .unrecoverable_err => |err| {
                    // in case the parser encounters a malformed request and can't safely continue parsing we have to drop the whole buffer
                    // the io thread will drop the connection so this is just cleanup

                    self.input_buffer_pool.release(self.current_buffer_idx.?);
                    self.current_buffer_idx = null;
                    self.parser = null;

                    return MessageReadResult{
                        .unrecoverable_parser_error = err,
                    };
                },
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
