const std = @import("std");
const posix = std.posix;

const Serializer = @import("serializer/serializer.zig").Serializer;
const CountingSerializer = @import("serializer/counting-serializer.zig").Serializer;
const serializeMessageHeaders = @import("message-headers/serialize-message-headers.zig").serializeMessageHeaders;
const deserializeMessageHeaders = @import("message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;
const RequestHeaders = @import("message-headers/request-headers.zig").RequestHeaders;

const Client = @import("client/client.zig").Client;
const ClientOptions = @import("client/client-options.zig").ClientOptions;
const TestContract = @import("server-main.zig").TestContract;

pub fn main() !void {
    var client = try Client(.{ .server_contracts = &.{TestContract} }).init(std.heap.page_allocator);
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try client.connect(address);

    const result = (try client.fetch(TestContract.add, .{12345})).await() catch |err| {
        std.debug.print("Server returned an error response: {}\n", .{err});
        return;
    };

    std.debug.print("{}\n", .{result});
    try client.deinit();

    // keep the program alive to allow background network thread to operate, todo: get rid of this
    std.Thread.sleep(100000000000);
}

fn getMethodId(comptime options: ClientOptions, comptime method: anytype) struct { u16, u16 } {
    inline for (options.server_contracts, 0..) |TContract, contract_id| {
        inline for (@typeInfo(TContract).@"struct".decls, 0..) |decl, method_id| {
            const m = @field(TContract, decl.name);
            if (@TypeOf(m) == @TypeOf(method) and m == method) {
                return .{ contract_id, method_id }; // todo: hardcoded contract id
            }
        }
    }

    @compileError("Method not found in any of the registered contracts");
}

const ASDContract = struct {
    pub fn add(a: i32) AddErrors!i32 {
        if (a > 5)
            return error.ValOver5;

        return a;
    }
};

pub const AddErrors = error{
    ValOver5,
};
