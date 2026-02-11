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
const Promise = @import("../promise/promise.zig").Promise;

const OutboundMessage = @import("outbound_message.zig").OutboundMessage;
const InboundMessage = @import("inbound_message.zig").InboundMessage;

const PendingRequestsMap = @import("pending_requests_map.zig").PendingRequestsMap;

const ServerConnection = @import("server_connection.zig").ServerConnection;

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

    server_connection: *ServerConnection,

    workers: []Worker = undefined,

    outbound_buffer: []OutboundMessage,
    outbound_queue: *Queue(OutboundMessage),

    inbound_buffer: []InboundMessage,
    inbound_queue: *Queue(InboundMessage),

    pub fn init(allocator: std.mem.Allocator, comptime options: ClientOptions) !*Client {
        const outbound_buffer = try allocator.alloc(OutboundMessage, options.max_outbound_messages);
        const outbound_queue = try allocator.create(Queue(OutboundMessage));
        outbound_queue.* = try Queue(OutboundMessage).init(outbound_buffer);

        const inbound_buffer = try allocator.alloc(InboundMessage, options.max_inbound_messages);
        const inbound_queue = try allocator.create(Queue(InboundMessage));
        inbound_queue.* = try Queue(InboundMessage).init(inbound_buffer);

        const pending_requests_map = try allocator.create(PendingRequestsMap);
        pending_requests_map.* = try PendingRequestsMap.init(allocator, options.max_outbound_messages);

        const inbound_buffer_pool = try allocator.create(BufferPool);
        inbound_buffer_pool.* = try BufferPool.init(allocator, options.max_inbound_messages, options.read_buffer_size);

        const outbound_buffer_pool = try allocator.create(BufferPool);
        outbound_buffer_pool.* = try BufferPool.init(allocator, options.max_outbound_messages, options.write_buffer_size);

        const server_connection = try allocator.create(ServerConnection);

        const workers = try allocator.alloc(Worker, options.worker_thread_count);

        const self = try allocator.create(Client);
        self.* = Client{
            .options = options,
            .allocator = allocator,

            .deserializer = Deserializer.init(allocator),

            .outbound_buffer = outbound_buffer,
            .outbound_queue = outbound_queue,

            .inbound_buffer = inbound_buffer,
            .inbound_queue = inbound_queue,

            .pending_requests_map = pending_requests_map,

            .inbound_buffer_pool = inbound_buffer_pool,
            .outbound_buffer_pool = outbound_buffer_pool,

            .workers = workers,

            .server_connection = server_connection,
        };

        server_connection.* = try ServerConnection.init(
            allocator,
            self,
        );

        return self;
    }

    pub fn deinit(self: *Client) !void {
        try self.disconnect();

        self.server_connection.deinit();

        self.allocator.free(self.workers);

        self.allocator.free(self.outbound_buffer);
        self.allocator.destroy(self.outbound_queue);
        self.allocator.free(self.inbound_buffer);
        self.allocator.destroy(self.inbound_queue);

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

        for (0..self.options.worker_thread_count) |i| {
            self.workers[i] = Worker.init(self.allocator, self);

            self.workers[i].runThread() catch |err| {
                std.debug.print("Failed to spawn worker thread {}: {}\n", .{ i, err });
                return err;
            };
        }
    }

    pub fn disconnect(self: *Client) !void {
        try self.server_connection.disconnect();

        self.inbound_queue.close();
        for (self.workers) |*w| {
            w.thread.join();
        }

        try self.pending_requests_map.clear();
        while (self.inbound_queue.tryPop()) |in_msg| {
            self.allocator.free(in_msg.data);
        }
    }

    pub fn fetch(self: *Client, method: anytype, args: MethodTupleArg(method)) anyerror!*Promise(MethodReturnType(method)) {
        const ids = comptime getMethodId(method);
        const contract_id: u16 = ids.contract_id;
        const method_id: u16 = ids.method_id;

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

        const request_id = try self.pending_requests_map.insert(.{
            .promise = promise,
            .resolve = DeserilizeWrapper.resolve,
            .destroy = DeserilizeWrapper.destroy,
        });

        const payload_len = try CountingSerializer.serialize(@TypeOf(args), args);
        const headers = MessageHeaders{
            .Request = .{
                .version = app_version,
                .contract_id = contract_id,
                .flags = 0,
                .method_id = method_id,
                .msg_type = .Request,
                .request_id = request_id,
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
