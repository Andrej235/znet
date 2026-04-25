const std = @import("std");
const posix = std.posix;

const ConnectionReader = @import("./connection_reader.zig").ConnectionReader;

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;
const ConnectionId = @import("connection_id.zig").ConnectionId;

const Response = @import("../responses/response.zig").Response;
const ValidationError = @import("./validation_error.zig").ValidationError;

const Queue = @import("../queues/spsc_queue.zig").Queue;
const Job = @import("./job.zig").Job;
const OutMessage = @import("./out_message.zig").OutMessage;
const Logger = @import("../logger/logger.zig").Logger.scoped(.client_connection);

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
            self.output_buffer_pool.release(msg.buffer_idx);
        }

        self.reader.deinit();

        self.out_message_queue.deinit(self.allocator);
        self.allocator.destroy(self.out_message_queue);
    }

    pub const ReadResult = union(enum) {
        success,
        not_enough_data,
        parser_error: struct {
            keep_alive: bool,
            response: Response(ValidationError),
        },
        unrecoverable_parser_error: union(enum) {
            with_details: Response(ValidationError),
            generic: Response(void),
        },
    };

    pub fn readMessage(self: *ClientConnection) !ReadResult {
        const msg = try self.reader.readMessage(self.socket) orelse return .not_enough_data;

        switch (msg) {
            .success => |result| {
                try self.job_queue.tryPush(.{
                    .buffer_idx = result.buffer_idx,
                    .client_id = self.id,
                    .request = result.request,
                });

                // wake up the reactor thread to process this new job
                try self.waker.wake();

                return .success;
            },

            .parser_error => |err| {
                return .{
                    .parser_error = .{
                        .keep_alive = err.keep_alive,
                        .response = .{
                            .http = .init(err.validation_error.error_code, if (err.keep_alive) .keep_alive else .close, null, err.validation_error),
                        },
                    },
                };
            },

            .unrecoverable_parser_error => |err| {
                if (err) |e| {
                    return .{
                        .unrecoverable_parser_error = .{
                            .with_details = Response(ValidationError){
                                .http = .init(e.error_code, .close, null, e),
                            },
                        },
                    };
                } else {
                    return .{
                        .unrecoverable_parser_error = .{
                            .generic = Response(void){
                                .http = .init(.internal_server_error, .close, null, {}),
                            },
                        },
                    };
                }
            },
        }
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
