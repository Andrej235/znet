const std = @import("std");
const ClientConnection = @import("../client_connection.zig").ClientConnection;
const OutMessage = @import("../out_message.zig").OutMessage;
const SharedSlice = @import("../../utils/shared_slice.zig").SharedSlice;

const MessageHeadersByteSize = @import("../../message_headers/message_headers.zig").HeadersByteSize;
const serializeHeaders = @import("../../message_headers/serialize_message_headers.zig").serializeMessageHeaders;
const Serializer = @import("../../serializer/serializer.zig").Serializer;
const CountingSerializer = @import("../../serializer/counting_serializer.zig").Serializer;

const Client = @import("../../client//client.zig").Client;

const app_version = @import("../../app_version.zig").app_version;

pub const AudienceType = enum {
    sender,
    others,
    all,
};

pub const Audience = struct {
    allocator: std.mem.Allocator,
    client_connections: []const ClientConnection,
    connected_clients: []const u32,
    sender_id: u32,
    audience_type: AudienceType,
    wakeup_fd: std.posix.fd_t,

    pub fn broadcast(self: *Audience, method: anytype, args: MethodTupleArg(method)) !void {
        const ids = comptime getMethodId(method);
        const contract_id: u16 = ids.contract_id;
        const method_id: u16 = ids.method_id;

        const write_buffer = try self.allocator.alloc(u8, 1024); // todo: make this configurable, maybe reuse buffers
        defer self.allocator.free(write_buffer);

        var writer: std.io.Writer = .fixed(write_buffer);
        const payload_len = try CountingSerializer.serialize(@TypeOf(args), args);
        try serializeHeaders(&writer, .{
            .Broadcast = .{
                .version = app_version,
                .msg_type = .Broadcast,
                .flags = 0,
                .contract_id = contract_id,
                .method_id = method_id,
                .payload_len = payload_len,
            },
        });

        try Serializer.serialize(@TypeOf(args), &writer, args);

        const message = try self.allocator.alloc(u8, payload_len + MessageHeadersByteSize.Broadcast);
        @memcpy(message, write_buffer[0 .. payload_len + MessageHeadersByteSize.Broadcast]);

        // TODO:? replace allocations entirely with 2 slices pointing to a ring buffer (one for head, one for tail, where tail is only useful/non-empty when it wraps around i.e. starts back from the start). This needs to be implemented in unison with the same mechanism on job results/response side
        // TODO:? or use a buffer pool because a ring buffer for outgoing messages is problematic to say the least
        // for now message is freed by the network thread after ref count reaches 0
        const shared_slice = try SharedSlice(u8).create(self.allocator, message);
        const msg = OutMessage{
            .offset = 0,
            .data = .{
                .shared = shared_slice,
            },
        };

        switch (self.audience_type) {
            .sender => {
                const client = self.client_connections[self.sender_id];
                try client.out_message_queue.push(msg);
                shared_slice.retain();
            },
            .others => {
                for (self.connected_clients) |i| {
                    if (i == self.sender_id) continue;

                    const client = self.client_connections[i];
                    try client.out_message_queue.push(msg);
                    shared_slice.retain();
                }
            },
            .all => {
                for (self.connected_clients) |i| {
                    const client = self.client_connections[i];
                    try client.out_message_queue.push(msg);
                    shared_slice.retain();
                }
            },
        }
        shared_slice.release();

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
