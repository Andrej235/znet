const std = @import("std");
const linux = std.os.linux;

const PollerEvent = @import("../poller_event.zig").PollerEvent;

pub const LinuxEventIterator = struct {
    epoll_events: []linux.epoll_event,
    index: usize,
    count: usize,

    pub fn next(self: *LinuxEventIterator) ?PollerEvent {
        if (self.index >= self.count) return null;

        const event = self.epoll_events[self.index];
        self.index += 1;

        return PollerEvent{
            .index = event.data.u32,
            .in = (event.events & linux.EPOLL.IN) != 0,
            .out = (event.events & linux.EPOLL.OUT) != 0,
        };
    }
};
