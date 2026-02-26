const std = @import("std");
const windows = std.os.windows;
const posix = std.posix;
const ws2_32 = windows.ws2_32;
const Poller = @import("../poller/poller.zig");

pub const WindowsWaker = struct {
    wakeup_fd: posix.socket_t,
    send_fd: posix.socket_t,

    pub fn init() !WindowsWaker {
        const recv_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
        errdefer posix.close(recv_fd);

        var mode: u32 = 1;
        if (ws2_32.ioctlsocket(recv_fd, ws2_32.FIONBIO, &mode) == ws2_32.SOCKET_ERROR) return error.Unexpected;

        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        try posix.bind(recv_fd, &addr.any, addr.getOsSockLen());

        var len = addr.getOsSockLen();
        try posix.getsockname(recv_fd, &addr.any, &len);

        const send_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
        errdefer posix.close(send_fd);
        try posix.connect(send_fd, &addr.any, len);

        return WindowsWaker{
            .wakeup_fd = recv_fd,
            .send_fd = send_fd,
        };
    }

    pub fn register(self: *WindowsWaker, poller: *Poller, index: u32) !void {
        try poller.add(self.wakeup_fd, index, true, false);
    }

    pub fn wake(self: *WindowsWaker) !void {
        const buf = [_]u8{1};
        _ = try posix.send(self.send_fd, &buf, 0);
    }

    pub fn drain(self: *WindowsWaker) !void {
        var buf: [128]u8 = undefined;
        while (true) {
            _ = posix.recv(self.wakeup_fd, &buf, 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
        }
    }

    pub fn deinit(self: *WindowsWaker) void {
        posix.close(self.wakeup_fd);
        posix.close(self.send_fd);
    }
};
