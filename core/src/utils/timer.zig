const std = @import("std");

pub const Timer = struct {
    start_time_ms: i128,
    name: []const u8,

    pub inline fn start(name: []const u8) Timer {
        return Timer{
            .start_time_ms = std.time.nanoTimestamp(),
            .name = name,
        };
    }

    pub inline fn end(self: *const Timer) void {
        const end_time_ns = std.time.nanoTimestamp();
        const duration_ns = @as(f128, @floatFromInt(end_time_ns - self.start_time_ms));

        if (duration_ns < 1_000) {
            std.debug.print("{s}: {d:3} ns\n", .{ self.name, duration_ns });
        } else if (duration_ns < 1_000_000) {
            std.debug.print("{s}: {d:5.2} µs\n", .{ self.name, duration_ns / 1_000 });
        } else if (duration_ns < 1_000_000_000) {
            std.debug.print("{s}: {d:5.2} ms\n", .{ self.name, duration_ns / 1_000_000 });
        } else {
            std.debug.print("{s}: {d:5.2} s\n", .{ self.name, duration_ns / 1_000_000_000 });
        }
    }

    pub inline fn getDuration(self: *const Timer) f128 {
        const end_time_ns = std.time.nanoTimestamp();
        const duration_ns = @as(f128, @floatFromInt(end_time_ns - self.start_time_ms));
        return duration_ns;
    }
};
