const std = @import("std");
const builtin = @import("builtin");
const PollerEvent = @import("../poller_event.zig").PollerEvent;

const LinuxEventIterator = @import("linux_event_iterator.zig").LinuxEventIterator;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxEventIterator else @compileError("Unsupported OS");

pub fn next(self: *Self) ?PollerEvent {
    return self.impl.next();
}
