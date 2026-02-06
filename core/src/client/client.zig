const std = @import("std");
const posix = @import("std").posix;

const ClientOptions = @import("client_options.zig").ClientOptions;

const MessageHeaders = @import("../message_headers/message_headers.zig").MessageHeaders;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const MessageType = @import("../message_headers/message_type.zig").MessageType;
const serializeHeaders = @import("../message_headers/serialize_message_headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const ServerContext = @import("../server/context/context.zig").Context;

const Serializer = @import("../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../serializer/counting_serializer.zig").Serializer;
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const DeserializationErrors = @import("../serializer/errors.zig").DeserializationErrors;

const Queue = @import("../utils/mpmc_queue.zig").Queue;
const Promise = @import("../promise/promise.zig").Promise;

const OutboundMessage = @import("outbound_message.zig").OutboundMessage;
const InboundMessage = @import("inbound_message.zig").InboundMessage;
const PendingRequest = @import("pending_request.zig").PendingRequest;

const BroadcastHandlerFn = @import("handler_fn/broadcast_handler_fn.zig").BroadcastHandlerFn;
const createBroadcastHandlerFn = @import("handler_fn/create_broadcast_handler_fn.zig").createBroadcastHandlerFn;

const app_version: u8 = @import("../app_version.zig").app_version;

pub const Client = struct {
    pub const call_table = createCallTable();

    options: ClientOptions = .{},
    allocator: std.mem.Allocator,

    send_buffer: []u8,
    receive_buffer: []u8,
    read_pos: usize = 0,
    reader: std.io.Reader,

    deserializer: Deserializer,

    pending_requests_map: std.AutoHashMap(u32, PendingRequest),

    socket: posix.socket_t = undefined,

    // 0 is outbound queue wakeup, 1 is incoming data from server
    network_thread_polls: []posix.pollfd,
    outbound_wakeup_fd: posix.fd_t,

    outbound_buffer: []OutboundMessage,
    outbound_queue: *Queue(OutboundMessage),

    inbound_buffer: []InboundMessage,
    inbound_queue: *Queue(InboundMessage),

    current_request_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, comptime options: ClientOptions) !*Client {
        const send_buffer = try allocator.alloc(u8, options.write_buffer_size);
        const receive_buffer = try allocator.alloc(u8, options.read_buffer_size);

        const outbound_buffer = try allocator.alloc(OutboundMessage, options.max_outbound_messages);
        const outbound_queue = try allocator.create(Queue(OutboundMessage));
        outbound_queue.* = try Queue(OutboundMessage).init(outbound_buffer);

        const inbound_buffer = try allocator.alloc(InboundMessage, options.max_inbound_messages);
        const inbound_queue = try allocator.create(Queue(InboundMessage));
        inbound_queue.* = try Queue(InboundMessage).init(inbound_buffer);

        const network_thread_polls = try allocator.alloc(posix.pollfd, 2);
        const outbound_wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

        var pending_requests_map = std.AutoHashMap(u32, PendingRequest).init(allocator);
        try pending_requests_map.ensureTotalCapacity(options.max_pending_requests);

        const self = try allocator.create(Client);
        self.* = Client{
            .options = options,
            .allocator = allocator,

            .send_buffer = send_buffer,
            .receive_buffer = receive_buffer,
            .reader = std.io.Reader.fixed(receive_buffer),

            .deserializer = Deserializer.init(allocator),

            .outbound_buffer = outbound_buffer,
            .outbound_queue = outbound_queue,

            .inbound_buffer = inbound_buffer,
            .inbound_queue = inbound_queue,

            .pending_requests_map = pending_requests_map,

            .network_thread_polls = network_thread_polls,
            .outbound_wakeup_fd = outbound_wakeup_fd,
        };

        return self;
    }

    pub fn deinit(self: *Client) !void {
        var it = self.pending_requests_map.iterator();
        while (it.next()) |pending_request|
            try pending_request.value_ptr.destroy(pending_request.value_ptr.promise);

        self.allocator.free(self.send_buffer);
        self.allocator.free(self.receive_buffer);

        self.allocator.free(self.outbound_buffer);
        self.allocator.destroy(self.outbound_queue);
        self.allocator.free(self.inbound_buffer);
        self.allocator.destroy(self.inbound_queue);

        self.allocator.free(self.network_thread_polls);

        self.pending_requests_map.deinit();
        self.allocator.destroy(self);
    }

    pub fn connect(self: *Client, address: std.net.Address) !void {
        self.socket = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );

        self.outbound_wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

        self.network_thread_polls[0] = .{
            .fd = self.outbound_wakeup_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        self.network_thread_polls[1] = .{
            .fd = self.socket,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        _ = try posix.poll(self.network_thread_polls[1..], -1);
        while (true) {
            posix.connect(self.socket, &address.any, address.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            break;
        }

        _ = try std.Thread.spawn(.{}, networkThread, .{self});

        for (0..self.options.worker_thread_count) |_| {
            _ = try std.Thread.spawn(.{}, workerThread, .{self});
        }
    }

    pub fn disconnect(self: *Client) !void {
        posix.close(self.socket);
    }

    pub fn fetch(self: *Client, method: anytype, args: MethodTupleArg(method)) anyerror!*Promise(MethodReturnType(method)) {
        const ids = comptime getMethodId(method);
        const contract_id: u16 = ids.contract_id;
        const method_id: u16 = ids.method_id;

        const request_id = self.generateRequestId();
        const TResponse = MethodReturnType(method);
        const TPromise = Promise(TResponse);
        // allocated in init, must be deallocated by consumer
        const promise = try TPromise.init(self.allocator, &self.deserializer);

        const DeserilizeWrapper = struct {
            pub fn resolve(deserializer: *Deserializer, reader: *std.io.Reader, request_promise: *anyopaque) anyerror!void {
                const result = if (@typeInfo(TResponse) == .error_union) deserializer.deserialize(reader, TResponse) catch |err| switch (err) {
                    DeserializationErrors.AllocationFailed,
                    DeserializationErrors.BooleanDeserializationFailed,
                    DeserializationErrors.EndOfStream,
                    DeserializationErrors.IntegerDeserializationFailed,
                    DeserializationErrors.InvalidBooleanValue,
                    DeserializationErrors.InvalidUnionTag,
                    DeserializationErrors.OutOfMemory,
                    DeserializationErrors.UnexpectedEof,
                    => {
                        return error.DeserializationFailed;
                    },
                    else => @as(@typeInfo(TResponse).error_union.error_set, @errorCast(err)),
                } else deserializer.deserialize(reader, TResponse) catch return error.DeserializationFailed;

                const message_promise: *TPromise = @ptrCast(@alignCast(request_promise));
                message_promise.resolve(result);
            }

            pub fn destroy(request_promise: *anyopaque) !void {
                const message_promise: *TPromise = @ptrCast(@alignCast(request_promise));
                message_promise.destroyResult() catch |err| {
                    if (err != error.PromiseNotFulfilled) return err;
                };

                message_promise.deinit();
            }
        };

        try self.pending_requests_map.put(request_id, .{
            .promise = promise,
            .resolve = DeserilizeWrapper.resolve,
            .destroy = DeserilizeWrapper.destroy,
        });

        const SerializeWrapper = struct {
            pub fn serialize(message: OutboundMessage, writer: *std.io.Writer) anyerror!MessageHeaders {
                const message_args: *@TypeOf(args) = @ptrCast(@alignCast(message.args));
                defer message.allocator.destroy(message_args);

                const payload_len = try CountingSerializer.serialize(@TypeOf(message_args), message_args);
                const headers = MessageHeaders{
                    .Request = .{
                        .version = app_version,
                        .contract_id = contract_id,
                        .flags = 0,
                        .method_id = method_id,
                        .msg_type = .Request,
                        .request_id = message.request_id,
                        .payload_len = payload_len,
                    },
                };
                try serializeHeaders(writer, headers);

                try Serializer.serialize(@TypeOf(message_args), writer, message_args);

                return headers;
            }
        };

        // freed in network thread after sending by SerializeWrapper.serialize
        const heap_args = try self.allocator.create(@TypeOf(args));
        heap_args.* = args;

        try self.outbound_queue.push(.{
            .request_id = request_id,
            .promise = promise,
            .allocator = self.allocator,
            .serialize = SerializeWrapper.serialize,
            .args = heap_args,
        });

        // notify the network thread that a new outbound message is available
        _ = try std.posix.write(self.outbound_wakeup_fd, std.mem.asBytes(&@as(u64, 1)));

        return promise;
    }

    fn getMethodId(comptime method: anytype) struct { contract_id: u16, method_id: u16 } {
        inline for (@import("znet_contract_registry").server_contracts, 0..) |TContract, contract_id| {
            inline for (@typeInfo(TContract).@"struct".decls, 0..) |decl, method_id| {
                const m = @field(TContract, decl.name);
                if (@TypeOf(m) == @TypeOf(method) and m == method) {
                    return .{ .contract_id = contract_id, .method_id = method_id };
                }
            }
        }

        @compileError("Method not found in any of the registered contracts");
    }

    fn MethodTupleArg(comptime method: anytype) type {
        const arg_fields = comptime getParamTupleFields(@TypeOf(method));
        const argument = comptime @Type(.{
            .@"struct" = .{
                .is_tuple = true,
                .backing_integer = null,
                .layout = .auto,
                .decls = &.{},
                .fields = arg_fields,
            },
        });

        return argument;
    }

    pub fn getParamTupleFields(comptime TFn: type) []std.builtin.Type.StructField {
        const fn_info = @typeInfo(TFn);
        if (fn_info != .@"fn") @compileError("Expected function type");

        if (fn_info.@"fn".params[0].type == ServerContext)
            @compileError("Context must be injected as a pointer");

        const inject_context: bool = fn_info.@"fn".params[0].type == *ServerContext;
        const fields_len = if (inject_context) fn_info.@"fn".params.len - 1 else fn_info.@"fn".params.len;

        var fields: [fields_len]std.builtin.Type.StructField = undefined;
        const params = if (inject_context) fn_info.@"fn".params[1..] else fn_info.@"fn".params;

        for (params, 0..) |param, idx| {
            if (param.type) |T| {
                fields[idx] = .{
                    .name = std.fmt.comptimePrint("{}", .{idx}),
                    .type = T,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                };
            }
        }

        return &fields;
    }

    fn MethodReturnType(comptime method: anytype) type {
        const type_info = @typeInfo(@TypeOf(method));
        const fn_info = switch (type_info) {
            .@"fn" => |@"fn"| @"fn",
            .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
                .@"fn" => |fn_info| fn_info,
                else => @compileError("AsyncMethodReturnType only supports function types"),
            },
            else => @compileError("AsyncMethodReturnType only supports function types"),
        };

        const ReturnType = fn_info.return_type orelse void;
        return ReturnType;
    }

    fn generateRequestId(self: *Client) u32 {
        self.current_request_id += 1;
        return self.current_request_id;
    }

    fn writeAll(socket: posix.socket_t, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            sent += try posix.write(socket, data[sent..]);
        }
    }

    fn safeReadMessage(self: *Client, socket: posix.socket_t) !?[]u8 {
        const msg = self.readMessage(socket) catch |err| switch (err) {
            error.WouldBlock, error.NotOpenForReading => return null,
            else => return err,
        };
        return msg;
    }

    fn readMessage(self: *Client, socket: posix.socket_t) ![]u8 {
        while (true) {
            // loop until we have a full message to process
            if (try self.bufferedMessage()) |msg|
                return msg;

            // read more data from the socket, fills up the buffer from pos to the end
            const n = try posix.read(socket, self.receive_buffer[self.read_pos..]);
            if (n == 0) // no more data, connection closed or EOF
                return error.Closed;

            self.read_pos += n;
        }
    }

    fn bufferedMessage(self: *Client) !?[]u8 {
        // response and broadcast headers have the same size
        if (self.read_pos < MessageHeadersByteSize.Response) {
            // not enough data to read the header
            return null;
        }

        // payload_len is in the same position for both response and broadcast headers
        const payload_len = std.mem.readInt(u32, self.receive_buffer[MessageHeadersByteSize.Response - 4 .. MessageHeadersByteSize.Response], .big);

        const message_len = payload_len + MessageHeadersByteSize.Response;

        if (self.read_pos < message_len) {
            // not enough data to read the full message
            return null;
        }

        const msg = self.receive_buffer[0..message_len];

        // todo: replace with a ring buffer for zero-copy and no allocations
        // freed in worker thread after processing
        const heap_msg = try self.allocator.alloc(u8, msg.len);
        @memcpy(heap_msg, msg);

        // shift remaining data to the front of the buffer
        @memmove(self.receive_buffer[0 .. self.read_pos - message_len], self.receive_buffer[message_len..self.read_pos]);
        self.read_pos -= message_len;
        self.reader.seek = 0;

        return heap_msg;
    }

    fn networkThread(self: *Client) !void {
        while (true) {
            _ = try posix.poll(self.network_thread_polls, -1);

            // process outbound messages
            if (self.network_thread_polls[0].revents != 0) {
                while (self.outbound_queue.tryPop()) |out_msg| {
                    var writer: std.io.Writer = .fixed(self.send_buffer);
                    const headers = try out_msg.serialize(out_msg, &writer);
                    switch (headers) {
                        .Request => |req_headers| {
                            const total_len = req_headers.payload_len + MessageHeadersByteSize.Request;
                            try writeAll(self.socket, self.send_buffer[0..total_len]);
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
                _ = try std.posix.read(self.outbound_wakeup_fd, std.mem.asBytes(&buf));
            }

            // process inbound messages
            if (self.network_thread_polls[1].revents & posix.POLL.IN == posix.POLL.IN) {
                while (try self.safeReadMessage(self.socket)) |message| {
                    try self.inbound_queue.push(.{
                        .payload = message,
                    });
                }
            }
        }
    }

    fn workerThread(self: *Client) !void {
        while (true) {
            const in_msg = try self.inbound_queue.pop();
            defer self.allocator.free(in_msg.payload);
            var reader = std.io.Reader.fixed(in_msg.payload);
            const headers = try deserializeMessageHeaders(&reader);

            switch (headers) {
                .Request => {
                    std.debug.print("Unexpected Request message found in inbound queue\n", .{});
                    return;
                },
                .Response => |response| {
                    if (self.pending_requests_map.get(response.request_id)) |pending_request| {
                        pending_request.resolve(&self.deserializer, &reader, pending_request.promise) catch |err| {
                            std.debug.print("Error resolving request_id {d}: {}\n", .{ response.request_id, err });
                        };

                        _ = self.pending_requests_map.remove(response.request_id);
                    } else {
                        std.debug.print("No pending request found for request_id: {d}\n", .{response.request_id});
                    }
                },
                .Broadcast => |broadcast| {
                    if (comptime call_table.len == 0) return;

                    const handler = call_table[broadcast.contract_id][broadcast.method_id];
                    try handler(self, self.allocator, &reader);
                },
            }
        }
    }
};

pub fn createCallTable() []const []const BroadcastHandlerFn {
    return comptime blk: {
        var call_table: []const []const BroadcastHandlerFn = &.{};
        for (@import("znet_contract_registry").client_contracts) |TContract| {
            var handlers: []const BroadcastHandlerFn = &.{};

            const info = @typeInfo(TContract);
            if (info != .@"struct") continue;
            const decls = info.@"struct".decls;

            for (decls) |decl| {
                const fn_name = decl.name;
                const fn_impl = @field(TContract, fn_name);

                if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                handlers = handlers ++ @as([]const BroadcastHandlerFn, &.{createBroadcastHandlerFn(fn_impl)});
            }
            call_table = call_table ++ @as([]const []const BroadcastHandlerFn, &.{handlers});
        }

        break :blk call_table;
    };
}
