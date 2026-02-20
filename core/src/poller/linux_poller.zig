const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const LinuxPoller = struct {
    epoll_events: []linux.epoll_event,
    epoll_fd: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_events_count: usize) !LinuxPoller {
        const epoll_events = try allocator.alloc(linux.epoll_event, max_events_count);
        for (epoll_events) |*e| {
            e.* = .{
                .data = .{ .u32 = 0 },
                .events = 0,
            };
        }

        const epoll_fd = linux.epoll_create();

        return LinuxPoller{
            .epoll_events = epoll_events,
            .epoll_fd = @intCast(epoll_fd),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LinuxPoller) void {
        _ = linux.close(self.epoll_fd);
        self.allocator.free(self.epoll_events);
    }

    pub fn wait(self: *LinuxPoller, timeout_ms: i32) usize {
        return linux.epoll_wait(self.epoll_fd, self.epoll_events.ptr, @intCast(self.epoll_events.len), timeout_ms);
    }

    pub fn add(
        self: *LinuxPoller,
        fd: posix.fd_t,
        index: u32,
        comptime in: bool,
        comptime out: bool,
    ) !void {
        const events = comptime blk: {
            var ev: u32 = 0;
            if (in) ev |= linux.EPOLL.IN;
            if (out) ev |= linux.EPOLL.OUT;
            break :blk ev;
        };

        var listener_event: linux.epoll_event = .{
            .data = .{
                .u32 = index,
            },
            .events = events,
        };
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &listener_event);
    }

    pub fn modify(
        self: *LinuxPoller,
        fd: posix.fd_t,
        index: u32,
        comptime in: bool,
        comptime out: bool,
    ) !void {
        const events = comptime blk: {
            var ev: u32 = 0;
            if (in) ev |= linux.EPOLL.IN;
            if (out) ev |= linux.EPOLL.OUT;
            break :blk ev;
        };

        var listener_event: linux.epoll_event = .{
            .data = .{
                .u32 = index,
            },
            .events = events,
        };
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &listener_event);
    }

    pub fn remove(self: *LinuxPoller, fd: posix.fd_t) !void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
    }
};
