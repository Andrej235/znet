const std = @import("std");
const posix = std.posix;
const net = std.net;

const ServerOptions = @import("server_options.zig").ServerOptions;
const HandlerFn = @import("handler_fn/handler_fn.zig").HandlerFn;
const createHandlerFn = @import("handler_fn/create_handler_fn.zig").createHandlerFn;

const Reactor = @import("reactor.zig").Reactor;

pub const Server = struct {
    pub const call_table = createCallTable();

    options: ServerOptions,
    allocator: std.mem.Allocator,

    reactor: *Reactor,

    pub fn init(allocator: std.mem.Allocator, comptime options: ServerOptions) !*Server {
        const reactor = try Reactor.init(allocator, call_table, options);

        const self = try allocator.create(Server);
        self.* = .{
            .options = options,
            .allocator = allocator,

            .reactor = reactor,
        };

        return self;
    }

    pub fn run(self: *Server, address: net.Address) !void {
        try self.reactor.run(address);
    }

    pub fn deinit(self: *Server) !void {
        try self.stop();
        try self.reactor.deinit();

        self.allocator.destroy(self);
    }

    pub fn stop(self: *Server) !void {
        self.reactor.stop_flag.store(true, .release);
        _ = try posix.write(self.reactor.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));
    }
};

pub fn createCallTable() []const []const HandlerFn {
    comptime {
        var call_table: []const []const HandlerFn = &.{};
        for (@import("znet_contract_registry").server_contracts) |TContract| {
            var handlers: []const HandlerFn = &.{};

            const info = @typeInfo(TContract);
            if (info != .@"struct") continue;
            const decls = info.@"struct".decls;

            for (decls) |decl| {
                const fn_name = decl.name;
                const fn_impl = @field(TContract, fn_name);

                if (@typeInfo(@TypeOf(fn_impl)) != .@"fn") continue;
                handlers = handlers ++ @as([]const HandlerFn, &.{createHandlerFn(fn_impl)});
            }
            call_table = call_table ++ @as([]const []const HandlerFn, &.{handlers});
        }

        return call_table;
    }
}
