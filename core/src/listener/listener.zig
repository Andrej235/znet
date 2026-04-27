const std = @import("std");
const builtin = @import("builtin");
const Poller = @import("../poller/poller.zig");
const IoThread = @import("../server/io-thread.zig").IoThread;

const LinuxListener = @import("linux_listener.zig").LinuxListener;
const WindowsListener = @import("windows_listener.zig").WindowsListener;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxListener else if (builtin.os.tag == .windows) WindowsListener else @compileError("Unsupported OS");

/// Create listening socket
pub fn init(address: std.net.Address) !Self {
    return Self{
        .impl = try Impl.init(address),
    };
}

/// Close listener
pub fn deinit(self: *Self) void {
    self.impl.deinit();
}

/// Register listener with poller
pub fn register(self: *Self, poller: *Poller, index: u32) !void {
    try self.impl.register(poller, index);
}

/// Called for all pending connections.
/// Provided `client_registry` is used to register new client connections
/// and MUST have a method `attachClientSocket(self: *Self, socket: std.posix.socket_t, address: std.net.Address)` for that purpose.
pub fn drainAccepts(
    self: *Self,
    client_registry: anytype,
) !void {
    comptime {
        var T = @TypeOf(client_registry);
        var info = @typeInfo(T);

        if (info == .pointer and info.pointer.size == .one) {
            T = info.pointer.child;
            info = @typeInfo(T);
        }

        if (info != .@"struct") @compileError("client_registry must be a struct");

        if (!@hasDecl(T, "attachClientSocket"))
            @compileError("client_registry must implement method attachClientSocket(self: *Self, socket: posix.socket_t, address: std.net.Address)");

        const attach_fn = @field(T, "attachClientSocket");
        const TAttachFn = @TypeOf(attach_fn);
        const attach_fn_info = @typeInfo(TAttachFn);

        if (attach_fn_info != .@"fn")
            @compileError("attachClientSocket must be a function");

        const attach_fn_params = attach_fn_info.@"fn".params;
        if (attach_fn_params.len != 3)
            @compileError("attachClientSocket must have exactly 3 parameters");

        if (attach_fn_params[1].type != std.posix.socket_t)
            @compileError("Second parameter of attachClientSocket must be of type posix.socket_t");

        if (attach_fn_params[2].type != std.net.Address)
            @compileError("Third parameter of attachClientSocket must be of type std.net.Address");
    }

    try self.impl.drainAccepts(client_registry);
}
