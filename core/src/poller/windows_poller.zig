const std = @import("std");
const windows = std.os.windows;
const posix = std.posix;

const EventIterator = @import("event_iterator/event_iterator.zig");
const WindowsEventIterator = @import("event_iterator/windows_event_iterator.zig").WindowsEventIterator;

pub const WindowsPoller = struct {
    poll_fds: std.ArrayListUnmanaged(posix.pollfd),
    indices: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_events_count: usize) !WindowsPoller {
        var poll_fds = std.ArrayListUnmanaged(posix.pollfd){};
        try poll_fds.ensureTotalCapacity(allocator, max_events_count);

        var indices = std.ArrayListUnmanaged(u32){};
        try indices.ensureTotalCapacity(allocator, max_events_count);

        return WindowsPoller{
            .poll_fds = poll_fds,
            .indices = indices,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WindowsPoller) void {
        self.poll_fds.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    pub fn wait(self: *WindowsPoller, timeout_ms: i32) EventIterator {
        const count = posix.poll(self.poll_fds.items, timeout_ms) catch |err| {
            var buff: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(buff[0..], "Failed to poll: {}", .{err}) catch unreachable;
            @panic(msg);
        };

        return EventIterator{
            .impl = WindowsEventIterator{
                .poll_fds = self.poll_fds.items,
                .indices = self.indices.items,
                .index = 0,
                .ready_remaining = @intCast(count),
            },
        };
    }

    pub fn add(
        self: *WindowsPoller,
        fd_raw: *anyopaque,
        index: u32,
        in: bool,
        out: bool,
    ) !void {
        const socket: posix.socket_t = @ptrCast(@alignCast(fd_raw));

        var events: i16 = 0;
        if (in) events |= posix.POLL.IN;
        if (out) events |= posix.POLL.OUT;

        try self.poll_fds.append(self.allocator, .{
            .fd = socket,
            .events = events,
            .revents = 0,
        });
        try self.indices.append(self.allocator, index);
    }

    pub fn modify(
        self: *WindowsPoller,
        fd_raw: *anyopaque,
        index: u32,
        in: bool,
        out: bool,
    ) !void {
        const socket: posix.socket_t = @ptrCast(@alignCast(fd_raw));
        for (self.poll_fds.items, 0..) |*pfd, i| {
            if (pfd.fd == socket) {
                var events: i16 = 0;
                if (in) events |= posix.POLL.IN;
                if (out) events |= posix.POLL.OUT;
                pfd.events = events;
                self.indices.items[i] = index;
                return;
            }
        }
    }

    pub fn remove(self: *WindowsPoller, fd_raw: *anyopaque) !void {
        const socket: posix.socket_t = @ptrCast(@alignCast(fd_raw));
        for (self.poll_fds.items, 0..) |pfd, i| {
            if (pfd.fd == socket) {
                _ = self.poll_fds.swapRemove(i);
                _ = self.indices.swapRemove(i);
                return;
            }
        }
    }
};
