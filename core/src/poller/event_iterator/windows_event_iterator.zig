const std = @import("std");
const posix = std.posix;
const PollerEvent = @import("../poller_event.zig").PollerEvent;

pub const WindowsEventIterator = struct {
    poll_fds: []posix.pollfd,
    indices: []u32,
    index: usize,
    ready_remaining: i32,

    pub fn next(self: *WindowsEventIterator) ?PollerEvent {
        if (self.ready_remaining <= 0) return null;

        while (self.index < self.poll_fds.len) {
            const pfd = self.poll_fds[self.index];
            const idx = self.indices[self.index];
            self.index += 1;

            if (pfd.revents != 0) {
                self.ready_remaining -= 1;
                return PollerEvent{
                    .index = idx,
                    .in = (pfd.revents & posix.POLL.IN) != 0,
                    .out = (pfd.revents & posix.POLL.OUT) != 0,
                };
            }
        }
        return null;
    }
};
