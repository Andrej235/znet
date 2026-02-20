const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Poller = @import("../poller/poller.zig");

pub const LinuxWaker = struct {
    wakeup_fd: i32,

    pub fn init() !LinuxWaker {
        const fd = try posix.eventfd(0, linux.EFD.NONBLOCK);

        return LinuxWaker{
            .wakeup_fd = fd,
        };
    }

    pub fn register(self: *LinuxWaker, poller: *Poller) !void {
        // todo: implement after implementing poller
        _ = self;
        _ = poller;
    }

    pub fn wake(self: *LinuxWaker) !void {
        const val: u64 = 1;

        _ = posix.write(
            self.wakeup_fd,
            std.mem.asBytes(&val),
        ) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }

    pub fn drain(self: *LinuxWaker) !void {
        var val: u64 = 0;

        _ = posix.read(
            self.wakeup_fd,
            std.mem.asBytes(&val),
        ) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }

    pub fn deinit(self: *LinuxWaker) void {
        _ = posix.close(self.wakeup_fd);
    }
};
