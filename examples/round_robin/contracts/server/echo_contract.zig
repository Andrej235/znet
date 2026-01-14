const std = @import("std");
const znet = @import("znet");

pub const EchoContract = struct {
    pub fn discard(message: []const u8) bool {
        _ = message;
        return true;
    }

    pub fn echo(message: []const u8) []const u8 {
        return std.heap.page_allocator.dupe(u8, message) catch unreachable;
    }

    pub fn echoWithWait(message: []const u8, wait: f32) []const u8 {
        std.Thread.sleep(@intFromFloat(wait * std.time.ns_per_s));
        return std.heap.page_allocator.dupe(u8, message) catch unreachable;
    }

    pub fn sendNBytes(n: u32) []const u8 {
        const buffer = std.heap.page_allocator.alloc(u8, n) catch unreachable;
        return buffer;
    }
};
