const ServerHandler = @import("server/handler_fn/handler_fn.zig").HandlerFn;
const createServerHandler = @import("server/handler_fn/create_handler_fn.zig").createHandlerFn;

const BroadcastHandler = @import("client/handler_fn/broadcast_handler_fn.zig").BroadcastHandlerFn;
const createBroadcastHandler = @import("client/handler_fn/create_broadcast_handler_fn.zig").createBroadcastHandlerFn;

const SchemaOptions = struct {
    server_contracts: []const type = undefined,
    broadcast_contracts: []const type = undefined,
};

pub fn Schema(comptime options: SchemaOptions) type {
    return struct {
        pub const server_contracts: []const type = options.server_contracts;
        pub const broadcast_contracts: []const type = options.broadcast_contracts;

        pub fn createServerCallTable() []const []const ServerHandler {
            comptime {
                var call_table: []const []const ServerHandler = &.{};
                for (options.server_contracts) |TContract| {
                    var handlers: []const ServerHandler = &.{};

                    const info = @typeInfo(TContract);
                    if (info != .@"struct") continue;
                    const decls = info.@"struct".decls;

                    for (decls) |decl| {
                        const fn_name = decl.name;
                        const fn_impl = @field(TContract, fn_name);

                        if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                        handlers = handlers ++ @as([]const ServerHandler, &.{createServerHandler(fn_impl)});
                    }
                    call_table = call_table ++ @as([]const []const ServerHandler, &.{handlers});
                }

                return call_table;
            }
        }

        pub fn createBroadcastCallTable() []const []const BroadcastHandler {
            comptime {
                var call_table: []const []const BroadcastHandler = &.{};
                for (@import("znet_contract_registry").server_contracts) |TContract| {
                    var handlers: []const BroadcastHandler = &.{};

                    const info = @typeInfo(TContract);
                    if (info != .@"struct") continue;
                    const decls = info.@"struct".decls;

                    for (decls) |decl| {
                        const fn_name = decl.name;
                        const fn_impl = @field(TContract, fn_name);

                        if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                        handlers = handlers ++ @as([]const BroadcastHandler, &.{createBroadcastHandler(fn_impl)});
                    }
                    call_table = call_table ++ @as([]const []const BroadcastHandler, &.{handlers});
                }

                return call_table;
            }
        }
    };
}
