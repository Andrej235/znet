const std = @import("std");
const posix = std.posix;
const net = std.net;

const ServerOptions = @import("server_options.zig").ServerOptions;

const HostRouter = @import("../router/host_router.zig").HostRouter;
const Reactor = @import("reactor.zig").Reactor;
const ReactorHandle = @import("reactor.zig").ReactorHandle;

pub const ShutdownState = enum(u8) {
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
    shutdown_state: std.atomic.Value(ShutdownState),
    router: *const HostRouter,

    reactors_ready_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: std.mem.Allocator, router: *const HostRouter, comptime options: ServerOptions) !*ServerInterface {
        const reactors = try allocator.alloc(ReactorHandle, options.reactor_thread_count);

        const self = try allocator.create(ServerInterface);
        self.* = .{
            .options = options,
            .allocator = allocator,

            .reactors = reactors,

            .shutdown_state = std.atomic.Value(ShutdownState).init(.running),
            .router = router,
        };

        return self;
    }

    pub fn run(self: *ServerInterface, address: net.Address) !void {
        for (self.reactors, 0..) |*reactor, idx| {
            const handle = try Reactor.init(
                self.allocator,
                address,
                &self.shutdown_state,
                idx,
                self.options,
                &self.reactors_ready_count,
                self.router,
            );

            reactor.* = handle;
        }

        while (self.reactors_ready_count.load(.acquire) < self.options.reactor_thread_count) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn join(self: *ServerInterface) void {
        for (self.reactors) |*reactor| {
            reactor.thread.join(); // this will only end once all threads have shut down
        }
    }

    pub fn deinit(self: *ServerInterface) DeinitError!void {
        if (self.shutdown_state.load(.acquire) == ShutdownState.running) {
            return DeinitError.ServerStillRunning;
        }

        self.allocator.free(self.reactors);
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *ServerInterface, mode: ShutdownMode) ShutdownError!void {
        if (self.shutdown_state.load(.acquire) != ShutdownState.running) {
            return ShutdownError.ServerNotRunning;
        }

        self.shutdown_state.store(if (mode == ShutdownMode.immediate) ShutdownState.immediate else ShutdownState.graceful, .release);

        for (self.reactors) |*reactor| {
            reactor.waker.wake() catch return ShutdownError.FailedToWakeReactor;
        }
    }
};

pub fn Server(comptime TApp: type) type {
    return struct {
        const Self = @This();

        interface: *ServerInterface,

        pub fn init(allocator: std.mem.Allocator, comptime options: ServerOptions) !Self {
            const router = try allocator.create(HostRouter);
            router.* = try TApp.compileRouter(allocator);

            const server_interface = try ServerInterface.init(allocator, router, options);

            return Self{
                .interface = server_interface,
            };
        }

        pub inline fn run(self: *const Self, address: net.Address) !void {
            try self.interface.run(address);
        }

        pub inline fn join(self: *const Self) void {
            self.interface.join();
        }

        pub inline fn deinit(self: *const Self) DeinitError!void {
            try self.interface.deinit();
        }

        pub inline fn shutdown(self: *const Self, mode: ShutdownMode) ShutdownError!void {
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
