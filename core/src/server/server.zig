const std = @import("std");
const posix = std.posix;
const net = std.net;

const ServerOptions = @import("server_options.zig").ServerOptions;
const HandlerFn = @import("handler_fn/handler_fn.zig").HandlerFn;
const createHandlerFn = @import("handler_fn/create_handler_fn.zig").createHandlerFn;

const Reactor = @import("reactor.zig").Reactor;
const ReactorHandle = @import("reactor.zig").ReactorHandle;

pub const ShutdownState = enum(u8) {
    running,
    graceful,
    immediate,
};

pub const Server = struct {
    pub const call_table = createCallTable();

    options: ServerOptions,
    allocator: std.mem.Allocator,

    reactors: []ReactorHandle,
    shutdown_state: std.atomic.Value(ShutdownState),

    pub fn init(allocator: std.mem.Allocator, comptime options: ServerOptions) !*Server {
        const reactor_count = 2;
        const reactors = try allocator.alloc(ReactorHandle, reactor_count);

        const self = try allocator.create(Server);
        self.* = .{
            .options = options,
            .allocator = allocator,

            .reactors = reactors,

            .shutdown_state = std.atomic.Value(ShutdownState).init(.running),
        };

        return self;
    }

    pub fn run(self: *Server, address: net.Address) !void {
        for (self.reactors, 0..) |*reactor, idx| {
            const handle = try Reactor.init(
                self.allocator,
                address,
                &self.shutdown_state,
                idx,
                self.options,
            );

            reactor.* = handle;
        }

        for (self.reactors) |*reactor| {
            reactor.thread.join(); // this will only end once all threads have shut down
        }
    }

    pub fn deinit(self: *Server) !void {
        try self.stop();

        self.allocator.free(self.reactors);
        self.allocator.destroy(self);
    }

    pub fn stop(self: *Server) !void {
        self.shutdown_state.store(.immediate, .release);

        for (self.reactors) |reactor| {
            _ = try posix.write(reactor.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));
        }
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
