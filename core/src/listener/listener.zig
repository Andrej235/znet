const std = @import("std");
const builtin = @import("builtin");
const Poller = @import("../poller/poller.zig");
const Reactor = @import("../server/reactor.zig").Reactor;

const LinuxListener = @import("linux_listener.zig").LinuxListener;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxListener else @compileError("Unsupported OS");

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
pub fn register(self: *Self, poller: *Poller) !void {
    try self.impl.register(poller);
}

/// Called for all pending connections.
pub fn drainAccepts(
    self: *Self,
    comptime TSchema: type,
    reactor: *Reactor(TSchema),
) !void {
    try self.impl.drainAccepts(TSchema, reactor);
}
