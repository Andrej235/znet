const std = @import("std");
const builtin = @import("builtin");

const LinuxPoller = @import("linux_poller.zig").LinuxPoller;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxPoller else @compileError("Unsupported OS");

pub fn init() !Self {
    return Self{
        .impl = try Impl.init(),
    };
}

// /// Wait for events, optionally with a timeout in milliseconds
// fn wait(self: *Self, timeout_ms: i32) !void {}

// /// Iterate over all events that became ready
// fn events(self: *Self) EventIterator {}

// /// Wake the poller from another thread
// fn wake(self: *Self) void {}

// /// Add a file descriptor / handle to the poller
// fn add(self: *Self, fd: usize, readable: bool, writable: bool) !void {}

// /// Modify interest in an existing fd / handle
// fn modify(self: *Self, fd: usize, readable: bool, writable: bool) !void {}

// /// Remove a fd / handle from the poller
// fn remove(self: *Self, fd: usize) !void {}
