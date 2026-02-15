const std = @import("std");
const posix = std.posix;
const net = std.net;

const ServerOptions = @import("server_options.zig").ServerOptions;
const HandlerFn = @import("handler_fn/handler_fn.zig").HandlerFn;
const createHandlerFn = @import("handler_fn/create_handler_fn.zig").createHandlerFn;

const Reactor = @import("reactor.zig").Reactor;
const ReactorHandle = @import("reactor.zig").ReactorHandle;

pub const ServerState = enum(u8) {
    running,
    graceful,
    immediate,
};

pub const ShutdownMode = enum {
    graceful,
    immediate,
};

const ServerInterface = struct {
    options: ServerOptions,
    allocator: std.mem.Allocator,

    reactors: []ReactorHandle,
    server_state: std.atomic.Value(ServerState),

    pub fn init(allocator: std.mem.Allocator, comptime options: ServerOptions) !*ServerInterface {
        const reactor_count = 2;
        const reactors = try allocator.alloc(ReactorHandle, reactor_count);

        const self = try allocator.create(ServerInterface);
        self.* = .{
            .options = options,
            .allocator = allocator,

            .reactors = reactors,

            .server_state = std.atomic.Value(ServerState).init(.running),
        };

        return self;
    }

    pub fn run(self: *ServerInterface, comptime TSchema: type, address: net.Address) !void {
        for (self.reactors, 0..) |*reactor, idx| {
            const handle = try Reactor(TSchema).init(
                self.allocator,
                address,
                &self.server_state,
                idx,
                self.options,
            );

            reactor.* = handle;
        }
    }

    pub fn join(self: *ServerInterface) void {
        for (self.reactors) |*reactor| {
            reactor.thread.join(); // this will only end once all threads have shut down
        }
    }

    pub fn deinit(self: *ServerInterface) DeinitError!void {
        if (self.server_state.load(.acquire) == ServerState.running) {
            return DeinitError.ServerStillRunning;
        }

        self.allocator.free(self.reactors);
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *ServerInterface, mode: ShutdownMode) ShutdownError!void {
        if (self.server_state.load(.acquire) != ServerState.running) {
            return ShutdownError.ServerNotRunning;
        }

        self.server_state.store(if (mode == ShutdownMode.immediate) ServerState.immediate else ServerState.graceful, .release);

        for (self.reactors) |reactor| {
            _ = posix.write(reactor.wakeup_fd, std.mem.asBytes(&@as(u64, 1))) catch return ShutdownError.FailedToWakeReactor;
        }
    }
};

pub fn Server(comptime TSchema: type) type {
    return struct {
        const Self = @This();

        interface: *ServerInterface,

        pub fn init(allocator: std.mem.Allocator, comptime options: ServerOptions) !Self {
            const server_interface = try ServerInterface.init(allocator, options);

            return Self{
                .interface = server_interface,
            };
        }

        pub fn run(self: *const Self, address: net.Address) !void {
            try self.interface.run(TSchema, address);
        }

        pub inline fn join(self: *const Self) void {
            self.interface.join();
        }

        pub fn deinit(self: *const Self) DeinitError!void {
            try self.interface.deinit();
        }

        pub fn shutdown(self: *const Self, mode: ShutdownMode) ShutdownError!void {
            try self.interface.shutdown(mode);
        }
    };
}

const ShutdownError = error{
    ServerNotRunning,
    FailedToWakeReactor,
};

const DeinitError = error{
    ServerStillRunning,
};
