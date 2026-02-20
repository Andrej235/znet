const std = @import("std");
const builtin = @import("builtin");
const Poller = @import("../poller/poller.zig");

const LinuxWaker = @import("linux_waker.zig").LinuxWaker;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxWaker else @compileError("Unsupported OS");

pub fn init() !Self {
    return Self{
        .impl = try Impl.init(),
    };
}

pub fn register(self: *Self, poller: *Poller, index: u32) !void {
    try self.impl.register(poller, index);
}

pub fn wake(self: *Self) !void {
    try self.impl.wake();
}

pub fn drain(self: *Self) !void {
    try self.impl.drain();
}

pub fn deinit(self: *Self) void {
    self.impl.deinit();
}
