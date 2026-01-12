const std = @import("std");
const ClientConnection = @import("../client_connection.zig").ClientConnection;
const BroadcastJob = @import("../broadcast_job.zig").BroadcastJob;
const Queue = @import("../../utils/mpmc_queue.zig").Queue;

const MessageHeadersByteSize = @import("../../message_headers/message_headers.zig").HeadersByteSize;
const serializeHeaders = @import("../../message_headers/serialize_message_headers.zig").serializeMessageHeaders;
const Serializer = @import("../../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../../serializer/counting_serializer.zig").Serializer;

const Client = @import("../../client//client.zig").Client;

const app_version = @import("../../app_version.zig").app_version;

pub const Audience = struct {
    allocator: std.mem.Allocator,
    client_connections: []const ClientConnection,
    selected_bitset: std.bit_set.DynamicBitSet,
    broadcast_job_queue: *Queue(BroadcastJob),
    wakeup_fd: std.posix.fd_t,

    pub fn broadcast(self: *Audience, method: anytype, args: MethodTupleArg(method)) !void {
        const ids = comptime getMethodId(method);
        const contract_id: u16 = ids.contract_id;
        const method_id: u16 = ids.method_id;

        const write_buffer = try self.allocator.alloc(u8, 4096); // todo: make this configurable, maybe reuse buffers
        defer self.allocator.free(write_buffer);

        var writer: std.io.Writer = .fixed(write_buffer);
        const payload_len = try CountingSerializer.serialize(@TypeOf(args), args);
        try serializeHeaders(&writer, .{
            .Broadcast = .{
                .version = app_version,
                .message_type = .Broadcast,
                .flags = 0,
                .contract_id = contract_id,
                .method_id = method_id,
                .payload_len = payload_len,
            },
        });

        try Serializer.serialize(@TypeOf(args), &writer, args);

        const message = try self.allocator.alloc(u8, payload_len + MessageHeadersByteSize.Broadcast);
        @memcpy(message, write_buffer[0 .. payload_len + MessageHeadersByteSize.Broadcast]);

        self.broadcast_job_queue.push(.{
            .bitset = self.selected_bitset,
            .message = message,
        });

        // message and bitset will be freed by the network thread
        // wake up the server to process the broadcast job
        _ = try std.posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));
    }
};

fn getMethodId(comptime method: anytype) struct { contract_id: u16, method_id: u16 } {
    inline for (@import("znet_contract_registry").client_contracts, 0..) |TContract, contract_id| {
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

    if (fn_info.@"fn".params[0].type == Client)
        @compileError("Client must be injected as a pointer");

    const inject_client: bool = fn_info.@"fn".params[0].type == *Client;
    const fields_len = if (inject_client) fn_info.@"fn".params.len - 1 else fn_info.@"fn".params.len;

    var fields: [fields_len]std.builtin.Type.StructField = undefined;
    const params = if (inject_client) fn_info.@"fn".params[1..] else fn_info.@"fn".params;

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
