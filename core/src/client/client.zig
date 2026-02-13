const std = @import("std");
const posix = @import("std").posix;

const ClientOptions = @import("client_options.zig").ClientOptions;

const MessageHeaders = @import("../message_headers/message_headers.zig").MessageHeaders;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const serializeHeaders = @import("../message_headers/serialize_message_headers.zig").serializeMessageHeaders;

const ServerContext = @import("../server/context/context.zig").Context;

const Serializer = @import("../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../serializer/counting_serializer.zig").Serializer;
const Deserializer = @import("../serializer/deserializer.zig").Deserializer;
const DeserializationErrors = @import("../serializer/errors.zig").DeserializationErrors;

const Queue = @import("../utils/mpmc_queue.zig").Queue;
const SPSCQueue = @import("../utils/spsc_queue.zig").Queue;
const Promise = @import("promise.zig").Promise;

const OutboundMessage = @import("outbound_message.zig").OutboundMessage;
const InboundMessage = @import("inbound_message.zig").InboundMessage;

const PendingRequestsMap = @import("pending_requests_map.zig").PendingRequestsMap;

const ServerConnection = @import("server_connection.zig").ServerConnection;
const PendingRequest = @import("pending_request.zig").PendingRequest;

const BroadcastHandlerFn = @import("handler_fn/broadcast_handler_fn.zig").BroadcastHandlerFn;
const createBroadcastHandlerFn = @import("handler_fn/create_broadcast_handler_fn.zig").createBroadcastHandlerFn;

const BufferPool = @import("../utils/buffer_pool.zig").BufferPool;

const Worker = @import("worker.zig").Worker;

const app_version: u8 = @import("../app_version.zig").app_version;

pub const Client = struct {
    pub const call_table = createCallTable();

    options: ClientOptions = .{},
    allocator: std.mem.Allocator,

    inbound_buffer_pool: *BufferPool,
    outbound_buffer_pool: *BufferPool,

    deserializer: Deserializer,
    pending_requests_map: *PendingRequestsMap,

    promise_mutex: std.Thread.Mutex = .{},
    promise_condition: std.Thread.Condition = .{},

    server_connection: *ServerConnection,

    outbound_buffer: []OutboundMessage,
    outbound_queue: *Queue(OutboundMessage),

    pub fn init(allocator: std.mem.Allocator, comptime options: ClientOptions) !*Client {
        const outbound_buffer = try allocator.alloc(OutboundMessage, options.max_outbound_messages);
        const outbound_queue = try allocator.create(Queue(OutboundMessage));
        outbound_queue.* = try Queue(OutboundMessage).init(outbound_buffer);

        const pending_requests_map = try allocator.create(PendingRequestsMap);

        const inbound_buffer_pool = try allocator.create(BufferPool);
        inbound_buffer_pool.* = try BufferPool.init(allocator, options.max_inbound_messages, options.read_buffer_size);

        const outbound_buffer_pool = try allocator.create(BufferPool);
        outbound_buffer_pool.* = try BufferPool.init(allocator, options.max_outbound_messages, options.write_buffer_size);

        const server_connection = try allocator.create(ServerConnection);

        const self = try allocator.create(Client);
        self.* = Client{
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

    pub fn deinit(self: *Client) !void {
        try self.disconnect();

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

    pub fn connect(self: *Client, address: std.net.Address) !void {
        try self.server_connection.connect(address);

        // todo: reimplement for broadcasts only
        // for (0..self.options.worker_thread_count) |i| {
        //     self.workers[i] = Worker.init(self.allocator, self);

        //     self.workers[i].runThread() catch |err| {
        //         std.debug.print("Failed to spawn worker thread {}: {}\n", .{ i, err });
        //         return err;
        //     };
        // }
    }

    pub fn disconnect(self: *Client) !void {
        try self.server_connection.disconnect();

        // self.inbound_queue.close();
        // for (self.workers) |*w| {
        //     w.thread.join();
        // }

        try self.pending_requests_map.clear();
    }

    pub fn fetch(self: *Client, method: anytype, args: MethodTupleArg(method)) anyerror!Promise(MethodReturnType(method)) {
        const ids = comptime getMethodId(method);
        const contract_id: u16 = ids.contract_id;
        const method_id: u16 = ids.method_id;

        const TResponse = MethodReturnType(method);
        const TPromise = Promise(TResponse);

        const request = try self.pending_requests_map.acquire();
        const promise = TPromise.init(request);

        const payload_len = try CountingSerializer.serialize(@TypeOf(args), args);
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

        try self.outbound_queue.push(.{
            .buffer_idx = buffer_idx,
            .data = buffer[0 .. payload_len + MessageHeadersByteSize.Request],
        });

        // notify the network thread that a new outbound message is available
        _ = try std.posix.write(self.server_connection.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));

        return promise;
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

fn getParamTupleFields(comptime TFn: type) []std.builtin.Type.StructField {
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
