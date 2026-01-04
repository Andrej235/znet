const std = @import("std");
const posix = @import("std").posix;

const ClientOptions = @import("client-options.zig").ClientOptions;

const MessageHeaders = @import("../message-headers/message-headers.zig").MessageHeaders;
const serializeHeaders = @import("../message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;

const Serializer = @import("../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../serializer/counting-serializer.zig").Serializer;
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const DeserializationErrors = @import("../serializer/errors.zig").DeserializationErrors;

const ContractsWrapper = @import("server-contracts-wrapper.zig").ContractsWrapper;
const createContracts = @import("server-contracts-wrapper.zig").createContracts;

const Queue = @import("../utils/mpmc-queue.zig").Queue;
const Promise = @import("../promise/promise.zig").Promise;

const OutboundMessage = @import("outbound-message.zig").OutboundMessage;
const InboundMessage = @import("inbound-message.zig").InboundMessage;
const PendingRequest = @import("pending-request.zig").PendingRequest;

const app_version: u8 = @import("../app-version.zig").app_version;

pub fn Client(comptime options: ClientOptions) type {
    return struct {
        const Self = @This();

        contracts: ContractsWrapper(Self, options),
        allocator: std.mem.Allocator,

        send_buffer: []u8,
        receive_buffer: []u8,
        read_pos: usize = 0,
        reader: std.io.Reader,

        deserialize: Deserializer,

        pending_requests_map: std.AutoHashMap(u32, PendingRequest),

        socket: posix.socket_t = undefined,

        // 0 is outbound queue wakeup, 1 is incoming data from server
        network_thread_polls: []posix.pollfd,
        // 0 is inbound queu wakeup
        worker_thread_polls: []posix.pollfd,

        outbound_buffer: []OutboundMessage,
        outbound_queue: *Queue(OutboundMessage),
        outbound_wakeup_fd: posix.fd_t,

        inbound_buffer: []InboundMessage,
        inbound_queue: *Queue(InboundMessage),
        inbound_wakeup_fd: posix.fd_t,

        current_request_id: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const send_buffer = try allocator.alloc(u8, options.write_buffer_size);
            const receive_buffer = try allocator.alloc(u8, options.read_buffer_size);

            const outbound_buffer = try allocator.alloc(OutboundMessage, options.max_outbound_messages);
            const outbound_queue = try allocator.create(Queue(OutboundMessage));
            outbound_queue.* = try Queue(OutboundMessage).init(outbound_buffer);

            const inbound_buffer = try allocator.alloc(InboundMessage, options.max_inbound_messages);
            const inbound_queue = try allocator.create(Queue(InboundMessage));
            inbound_queue.* = try Queue(InboundMessage).init(inbound_buffer);

            const network_thread_polls = try allocator.alloc(posix.pollfd, 2);
            const worker_thread_polls = try allocator.alloc(posix.pollfd, 1);

            const outbound_wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);
            const inbound_wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

            var pending_requests_map = std.AutoHashMap(u32, PendingRequest).init(allocator);
            try pending_requests_map.ensureTotalCapacity(options.max_pending_requests);

            const self = try allocator.create(Self);
            self.* = Self{
                .contracts = createContracts(Self, options),
                .allocator = allocator,

                .send_buffer = send_buffer,
                .receive_buffer = receive_buffer,
                .reader = std.io.Reader.fixed(receive_buffer),

                .deserialize = Deserializer{
                    .allocator = allocator,
                },

                .outbound_buffer = outbound_buffer,
                .outbound_queue = outbound_queue,
                .outbound_wakeup_fd = outbound_wakeup_fd,

                .inbound_buffer = inbound_buffer,
                .inbound_queue = inbound_queue,
                .inbound_wakeup_fd = inbound_wakeup_fd,

                .pending_requests_map = pending_requests_map,

                .network_thread_polls = network_thread_polls,
                .worker_thread_polls = worker_thread_polls,
            };

            return self;
        }

        pub fn deinit(self: *Self) !void {
            self.allocator.free(self.send_buffer);
            self.allocator.free(self.receive_buffer);

            self.allocator.free(self.outbound_buffer);
            self.allocator.destroy(self.outbound_queue);
            self.allocator.free(self.inbound_buffer);
            self.allocator.destroy(self.inbound_queue);

            self.allocator.free(self.network_thread_polls);
            self.allocator.free(self.worker_thread_polls);

            self.pending_requests_map.deinit();
            self.allocator.destroy(self);
        }

        pub fn connect(self: *Self, address: std.net.Address) !void {
            // networkThread will spawn the worker thread, connect the socket and create all polls
            _ = try std.Thread.spawn(.{}, networkThread, .{ self, address });
        }

        pub fn disconnect(self: *Self) !void {
            posix.close(self.socket);
        }

        pub fn call(self: *Self, comptime contract_id: u16, comptime method_id: u16, args: anytype) anyerror!*Promise(IdsToReturnType(options, contract_id, method_id)) {
            const request_id = self.generateRequestId();
            const TResponse = IdsToReturnType(options, contract_id, method_id);
            const TPromise = Promise(TResponse);
            // allocated in init, must deallocated by consumer
            const promise = try TPromise.init(self.allocator);

            const DeserilizeWrapper = struct {
                pub fn resolve(deserializer: *Deserializer, reader: *std.io.Reader, request_promise: *anyopaque) anyerror!void {
                    const headers = try deserializeMessageHeaders(reader);

                    switch (headers) {
                        .Request => {
                            return error.UnexpectedRequestInResponse;
                        },
                        .Broadcast => {
                            return error.UnexpectedBroadcastInResponse;
                        },
                        .Response => |resp_header| {
                            if (resp_header.version != app_version) {
                                return error.VersionMismatch;
                            }

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
                        },
                    }
                }
            };

            try self.pending_requests_map.put(request_id, .{
                .promise = promise,
                .resolve = DeserilizeWrapper.resolve,
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

            self.outbound_queue.push(.{
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

        pub fn fetch(self: *Self, method: anytype, args: MethodTupleArg(method)) anyerror!AsyncMethodReturnType(method) {
            const ids = comptime getMethodId(method);
            const contract_id: u16 = ids.contract_id;
            const method_id: u16 = ids.method_id;

            const request_id = self.generateRequestId();
            const TResponse = IdsToReturnType(options, contract_id, method_id);
            const TPromise = Promise(TResponse);
            // allocated in init, must deallocated by consumer
            const promise = try TPromise.init(self.allocator);

            const DeserilizeWrapper = struct {
                pub fn resolve(deserializer: *Deserializer, reader: *std.io.Reader, request_promise: *anyopaque) anyerror!void {
                    const headers = try deserializeMessageHeaders(reader);

                    switch (headers) {
                        .Request => {
                            return error.UnexpectedRequestInResponse;
                        },
                        .Broadcast => {
                            return error.UnexpectedBroadcastInResponse;
                        },
                        .Response => |resp_header| {
                            if (resp_header.version != app_version) {
                                return error.VersionMismatch;
                            }

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
                        },
                    }
                }
            };

            try self.pending_requests_map.put(request_id, .{
                .promise = promise,
                .resolve = DeserilizeWrapper.resolve,
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

            self.outbound_queue.push(.{
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
            inline for (options.server_contracts, 0..) |TContract, contract_id| {
                inline for (@typeInfo(TContract).@"struct".decls, 0..) |decl, method_id| {
                    const m = @field(TContract, decl.name);
                    if (@TypeOf(m) == @TypeOf(method) and m == method) {
                        return .{ .contract_id = contract_id, .method_id = method_id }; // todo: hardcoded contract id
                    }
                }
            }

            @compileError("Method not found in any of the registered contracts");
        }

        fn MethodTupleArg(comptime method: anytype) type {
            const type_info = @typeInfo(@TypeOf(method));
            const fn_info = switch (type_info) {
                .@"fn" => |@"fn"| @"fn",
                .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
                    .@"fn" => |fn_info| fn_info,
                    else => @compileError("MethodTupleArg only supports function types"),
                },
                else => @compileError("MethodTupleArg only supports function types"),
            };

            var arg_fields: [fn_info.params.len]std.builtin.Type.StructField = undefined;
            inline for (fn_info.params, 0..) |param, idx| {
                arg_fields[idx] = std.builtin.Type.StructField{
                    .name = std.fmt.comptimePrint("{}", .{idx}),
                    .type = param.type.?,
                    .alignment = @alignOf(param.type.?),
                    .is_comptime = false,
                    .default_value_ptr = null,
                };
            }

            const argument = @Type(.{
                .@"struct" = .{
                    .is_tuple = true,
                    .backing_integer = null,
                    .layout = .auto,
                    .decls = &.{},
                    .fields = &arg_fields,
                },
            });

            return argument;
        }

        fn AsyncMethodReturnType(comptime method: anytype) type {
            const type_info = @typeInfo(@TypeOf(method));
            const fn_info = switch (type_info) {
                .@"fn" => |@"fn"| @"fn",
                .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
                    .@"fn" => |fn_info| fn_info,
                    else => @compileError("AsyncMethodReturnType only supports function types"),
                },
                else => @compileError("AsyncMethodReturnType only supports function types"),
            };

            const ReturnType = *Promise(fn_info.return_type orelse void);
            return ReturnType;
        }

        fn generateRequestId(self: *Self) u32 {
            self.current_request_id += 1;
            return self.current_request_id;
        }

        fn writeAll(socket: posix.socket_t, data: []const u8) !void {
            var sent: usize = 0;
            while (sent < data.len) {
                sent += try posix.write(socket, data[sent..]);
            }
        }

        fn safeReadMessage(self: *Self, socket: posix.socket_t) !?[]u8 {
            const msg = self.readMessage(socket) catch |err| switch (err) {
                error.WouldBlock, error.NotOpenForReading => return null,
                else => return err,
            };
            return msg;
        }

        fn readMessage(self: *Self, socket: posix.socket_t) ![]u8 {
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

        fn bufferedMessage(self: *Self) !?[]u8 {
            if (self.read_pos < 10) {
                // not enough data to read the header
                return null;
            }

            const header = try deserializeMessageHeaders(&self.reader);
            const payload_len = header.Response.payload_len;

            const message_len = payload_len + 10;

            if (self.read_pos < message_len) {
                // not enough data to read the full message
                return null;
            }

            // copy out the full message before shifting the buffer
            const msg = self.receive_buffer[0..message_len];

            // shift remaining data to the front of the buffer
            @memmove(self.receive_buffer[0 .. self.read_pos - message_len], self.receive_buffer[message_len..self.read_pos]);
            self.read_pos -= message_len;
            self.reader.seek = 0;

            return msg;
        }

        fn networkThread(self: *Self, address: std.net.Address) !void {
            self.socket = try posix.socket(
                address.any.family,
                posix.SOCK.STREAM,
                posix.IPPROTO.TCP,
            );

            try posix.connect(self.socket, &address.any, address.getOsSockLen());

            self.network_thread_polls[0] = .{
                .fd = self.outbound_wakeup_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };

            self.network_thread_polls[1] = .{
                .fd = self.socket,
                .events = posix.POLL.IN | posix.POLL.OUT,
                .revents = 0,
            };

            _ = try std.Thread.spawn(.{}, workerThread, .{self});

            while (true) {
                _ = try posix.poll(self.network_thread_polls, -1);

                // process outbound messages
                if (self.network_thread_polls[0].revents != 0) {
                    while (self.outbound_queue.tryPop()) |out_msg| {
                        var writer: std.io.Writer = .fixed(self.send_buffer);
                        const headers = try out_msg.serialize(out_msg, &writer);
                        switch (headers) {
                            .Request => |req_headers| {
                                const total_len = req_headers.payload_len + 14; // header size = 14
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
                        self.inbound_queue.push(.{
                            .request_id = std.mem.readInt(u32, message[2..6], .big),
                            .payload = message,
                        });

                        // notify the worker thread that a new inbound message is available
                        _ = try std.posix.write(self.inbound_wakeup_fd, std.mem.asBytes(&@as(u64, 1)));
                    }
                }
            }
        }

        fn workerThread(self: *Self) !void {
            self.worker_thread_polls[0] = .{
                .fd = self.inbound_wakeup_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };

            while (true) {
                _ = try posix.poll(self.worker_thread_polls, -1);

                // process inbound messages
                if (self.worker_thread_polls[0].revents != 0) {
                    while (self.inbound_queue.tryPop()) |in_msg| {
                        if (self.pending_requests_map.get(in_msg.request_id)) |pending_request| {
                            var reader: std.io.Reader = .fixed(in_msg.payload);
                            pending_request.resolve(&self.deserialize, &reader, pending_request.promise) catch |err| {
                                std.debug.print("Error resolving request_id {d}: {}\n", .{ in_msg.request_id, err });
                            };

                            _ = self.pending_requests_map.remove(in_msg.request_id);
                        } else {
                            std.debug.print("No pending request found for request_id: {d}\n", .{in_msg.request_id});
                        }
                    }

                    // clear the wakeup event
                    var buf: u64 = 0;
                    _ = try std.posix.read(self.inbound_wakeup_fd, std.mem.asBytes(&buf));
                }
            }
        }
    };
}

fn IdsToReturnType(comptime options: ClientOptions, comptime contract_id: u16, comptime method_id: u16) type {
    const Contract = options.server_contracts[contract_id];

    const contract_info = @typeInfo(Contract);
    switch (contract_info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.decls, 0..) |decl, i| {
                const method = @field(Contract, decl.name);
                const methodType = @TypeOf(method);
                if (@typeInfo(methodType) != .@"fn")
                    i -= 1;

                if (i == method_id) {
                    const fn_info = @typeInfo(methodType).@"fn";
                    return fn_info.return_type orelse void;
                }
            }

            @compileError("Invalid method_id");
        },
        else => @compileError("Expected struct type for contract"),
    }
}
