const std = @import("std");

const ClientOptions = @import("client_options.zig").ClientOptions;

const MessageHeaders = @import("../message_headers/message_headers.zig").MessageHeaders;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const serializeHeaders = @import("../message_headers/serialize_message_headers.zig").serializeMessageHeaders;

const Serializer = @import("../serialization/binary/serializer.zig").Serializer;
const Deserializer = @import("../serialization/binary/deserializer.zig").Deserializer;

const Queue = @import("../queues/mpsc_queue.zig").Queue;
const Promise = @import("promise.zig").Promise;
const OutboundMessage = @import("outbound_message.zig").OutboundMessage;

const PendingRequestsMap = @import("pending_requests_map.zig").PendingRequestsMap;
const ServerConnection = @import("server_connection.zig").ServerConnection;

const ParamKind = @import("../app/params/param_kind.zig").ParamKind;

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;

const app_version: u8 = @import("../app_version.zig").app_version;

pub const ClientInterface = struct {
    options: ClientOptions = .{},
    allocator: std.mem.Allocator,

    inbound_buffer_pool: *BufferPool,
    outbound_buffer_pool: *BufferPool,

    deserializer: Deserializer,
    pending_requests_map: *PendingRequestsMap,

    server_connection: *ServerConnection,

    outbound_buffer: []OutboundMessage,
    outbound_queue: *Queue(OutboundMessage),

    pub fn init(allocator: std.mem.Allocator, comptime options: ClientOptions) !*ClientInterface {
        const outbound_buffer = try allocator.alloc(OutboundMessage, options.max_outbound_messages);
        const outbound_queue = try allocator.create(Queue(OutboundMessage));
        outbound_queue.* = try Queue(OutboundMessage).init(outbound_buffer);

        const pending_requests_map = try allocator.create(PendingRequestsMap);

        const inbound_buffer_pool = try allocator.create(BufferPool);
        inbound_buffer_pool.* = try BufferPool.init(allocator, options.max_inbound_messages, options.read_buffer_size);

        const outbound_buffer_pool = try allocator.create(BufferPool);
        outbound_buffer_pool.* = try BufferPool.init(allocator, options.max_outbound_messages, options.write_buffer_size);

        const server_connection = try allocator.create(ServerConnection);

        const self = try allocator.create(ClientInterface);
        self.* = ClientInterface{
            .options = options,
            .allocator = allocator,

            .deserializer = Deserializer.init(allocator),

            .outbound_buffer = outbound_buffer,
            .outbound_queue = outbound_queue,

            .pending_requests_map = pending_requests_map,

            .inbound_buffer_pool = inbound_buffer_pool,
            .outbound_buffer_pool = outbound_buffer_pool,

            .server_connection = server_connection,
        };

        self.pending_requests_map.* = try PendingRequestsMap.init(allocator, options.max_outbound_messages, self);

        server_connection.* = try ServerConnection.init(
            allocator,
            self,
        );

        return self;
    }

    pub fn deinit(self: *ClientInterface) !void {
        if (self.server_connection.connected.load(.acquire)) {
            return error.StillConnected;
        }

        self.server_connection.deinit();

        self.allocator.free(self.outbound_buffer);
        self.allocator.destroy(self.outbound_queue);

        self.inbound_buffer_pool.deinit(self.allocator);
        self.allocator.destroy(self.inbound_buffer_pool);

        self.outbound_buffer_pool.deinit(self.allocator);
        self.allocator.destroy(self.outbound_buffer_pool);

        self.allocator.destroy(self.server_connection);

        self.pending_requests_map.deinit();
        self.allocator.destroy(self.pending_requests_map);

        self.allocator.destroy(self);
    }

    pub fn connect(self: *ClientInterface, address: std.net.Address) ServerConnection.ConnectError!void {
        try self.server_connection.connect(address);
    }

    pub fn disconnect(self: *ClientInterface) !void {
        try self.server_connection.disconnect();
        try self.pending_requests_map.clear();
    }

    pub fn fetch(self: *ClientInterface, contract_id: u16, method_id: u16, method: anytype, args: HandlerBodyArg(@TypeOf(method))) anyerror!Promise(MethodReturnType(method)) {
        const TResponse = MethodReturnType(method);
        const TPromise = Promise(TResponse);

        const request = try self.pending_requests_map.acquire();
        const promise = TPromise.init(request);

        const payload_len = try Serializer.count(@TypeOf(args), args);
        const headers = MessageHeaders{
            .Request = .{
                .version = app_version,
                .contract_id = contract_id,
                .flags = 0,
                .method_id = method_id,
                .msg_type = .Request,
                .request_id = request.idx,
                .payload_len = payload_len,
            },
        };

        const buffer_idx = self.outbound_buffer_pool.acquire() orelse return error.OutOfBuffers;
        const buffer = self.outbound_buffer_pool.buffer(buffer_idx);
        var writer = std.io.Writer.fixed(buffer);

        try serializeHeaders(&writer, headers);
        try Serializer.serialize(@TypeOf(args), &writer, args);

        try self.outbound_queue.tryPush(.{
            .buffer_idx = buffer_idx,
            .data = buffer[0 .. payload_len + MessageHeadersByteSize.Request],
        });

        // notify the network thread that a new outbound message is available
        try self.server_connection.waker.wake();

        return promise;
    }
};

pub fn Client(comptime TApp: type) type {
    return struct {
        const Self = @This();

        interface: *ClientInterface,

        pub fn init(allocator: std.mem.Allocator, comptime options: ClientOptions) !Self {
            const interface = try ClientInterface.init(allocator, options);

            return Self{
                .interface = interface,
            };
        }

        pub fn deinit(self: *Self) !void {
            try self.interface.deinit();
        }

        pub fn connect(self: *const Self, address: std.net.Address) ServerConnection.ConnectError!void {
            try self.interface.connect(address);
        }

        pub fn disconnect(self: *const Self) !void {
            try self.interface.disconnect();
        }

        pub fn fetch(self: *const Self, method: anytype, args: HandlerBodyArg(@TypeOf(method))) anyerror!Promise(MethodReturnType(method)) {
            const method_id = comptime TApp.actionToId(method);
            return self.interface.fetch(method_id.scope_idx, method_id.action_idx, method, args);
        }
    };
}

fn HandlerBodyArg(comptime TFn: type) type {
    const fn_info = @typeInfo(TFn);
    if (fn_info != .@"fn") @compileError("Expected function type");

    for (fn_info.@"fn".params) |param| {
        const T = param.type orelse continue;

        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "param_kind") and @hasDecl(T, "Type")) {
            const param_kind: ParamKind = @field(T, "param_kind");

            if (param_kind == .body) {
                return @field(T, "Type");
            }
        }
    }

    return void;
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
