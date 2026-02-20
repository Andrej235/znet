const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const LinuxPoller = @import("linux_poller.zig").LinuxPoller;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxPoller else @compileError("Unsupported OS");

pub fn init(allocator: std.mem.Allocator, max_events_count: usize) !Self {
    return Self{
        .impl = try Impl.init(allocator, max_events_count),
    };
}

pub fn deinit(self: *Self) void {
    self.impl.deinit();
}

/// Wait for events, optionally with a timeout in milliseconds
pub fn wait(self: *Self, timeout_ms: i32) usize {
    return self.impl.wait(timeout_ms);
}

// /// Iterate over all events that became ready
// fn events(self: *Self) EventIterator {}

/// Add a file descriptor / handle to the poller
pub fn add(
    self: *Self,
    fd: posix.fd_t,
    index: u32,
    comptime in: bool,
    comptime out: bool,
) !void {
    try self.impl.add(fd, index, in, out);
}

/// Modify interest in an existing fd / handle
pub fn modify(
    self: *Self,
    fd: posix.fd_t,
    index: u32,
    comptime in: bool,
    comptime out: bool,
) !void {
    try self.impl.modify(fd, index, in, out);
}

/// Remove a fd / handle from the poller
pub fn remove(self: *Self, fd: posix.fd_t) !void {
    try self.impl.remove(fd);
}
