const std = @import("std");
const posix = @import("std").posix;

const ClientOptions = @import("client-options.zig").ClientOptions;

const MessageHeaders = @import("../message-headers/message-headers.zig").MessageHeaders;
const serializeHeaders = @import("../message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;

const Serializer = @import("../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../serializer/counting-serializer.zig").Serializer;
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;

const ContractsWrapper = @import("server-contracts-wrapper.zig").ContractsWrapper;
const createContracts = @import("server-contracts-wrapper.zig").createContracts;

const Queue = @import("../utils/mpmc-queue.zig").Queue;
const Promise = @import("../promise/promise.zig").Promise;
const OutboundMessage = @import("outbound-message.zig").OutboundMessage;

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

        socket: posix.socket_t = undefined,
        // 0 is outgoing queue wakeup, 1 is incoming data from server
        polls: []posix.pollfd,

        outbound_queue: *Queue(OutboundMessage),
        outgoing_wakeup_fd: posix.fd_t,

        current_request_id: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const send_buffer = try allocator.alloc(u8, 1024);
            const receive_buffer = try allocator.alloc(u8, 1024);

            const outbound_buffer = try allocator.alloc(OutboundMessage, 128);
            const outbound_queue = try allocator.create(Queue(OutboundMessage));
            outbound_queue.* = try Queue(OutboundMessage).init(outbound_buffer);

            const polls = try allocator.alloc(posix.pollfd, 2);
            const outgoing_wakeup_fd = try posix.eventfd(0, posix.SOCK.NONBLOCK);

            const self = try allocator.create(Self);
            self.* = Self{
                .contracts = createContracts(Self, options),
                .allocator = allocator,

                .send_buffer = send_buffer,
                .receive_buffer = receive_buffer,
                .reader = std.io.Reader.fixed(receive_buffer),

                .outbound_queue = outbound_queue,
                .polls = polls,
                .outgoing_wakeup_fd = outgoing_wakeup_fd,
            };

            _ = try std.Thread.spawn(.{}, networkThread, .{self});
            return self;
        }

        pub fn connect(self: *Self, address: std.net.Address) !void {
            self.socket = try posix.socket(
                address.any.family,
                posix.SOCK.STREAM,
                posix.IPPROTO.TCP,
            );

            try posix.connect(self.socket, &address.any, address.getOsSockLen());
        }

        pub fn disconnect(_: Self) void {
            std.debug.print("disconnecting... \n", .{});
        }

        pub fn call(self: *Self, comptime contract_id: u16, comptime method_id: u16, args: anytype) anyerror!*IdsToReturnType(options, contract_id, method_id) {
            const request_id = self.generateRequestId();
            const TPromise = IdsToReturnType(options, contract_id, method_id);
            const promise = try self.allocator.create(TPromise);
            promise.* = TPromise{};

            const SerializeWrapper = struct {
                pub fn serialize(message: OutboundMessage, writer: *std.io.Writer) anyerror!MessageHeaders {
                    const message_args: *@TypeOf(args) = @ptrCast(@alignCast(message.args));

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

            const heap_args = try self.allocator.create(@TypeOf(args));
            heap_args.* = args;

            self.outbound_queue.push(.{
                .request_id = request_id,
                .promise = promise,
                .serialize = SerializeWrapper.serialize,
                .args = heap_args,
            });

            // notify the network thread that a new outbound message is available
            _ = try std.posix.write(self.outgoing_wakeup_fd, std.mem.asBytes(&@as(u64, 1)));

            return promise;
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

        fn networkThread(self: *Self) !void {
            self.polls[0] = .{
                .fd = self.outgoing_wakeup_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };

            self.polls[1] = .{
                .fd = self.socket,
                .events = posix.POLL.IN,
                .revents = 0,
            };

            while (true) {
                _ = try posix.poll(self.polls, -1);

                // process outbound messages
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
                    }
                }

                // process inbound messages
                if (self.polls[1].revents & posix.POLL.IN != posix.POLL.IN) {
                    const message = try self.readMessage(self.socket);
                    std.debug.print("{any}\n", .{message});
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
                    return Promise(fn_info.return_type orelse void);
                }
            }

            @compileError("Invalid method_id");
        },
        else => @compileError("Expected struct type for contract"),
    }
}
