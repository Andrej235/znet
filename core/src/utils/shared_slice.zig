const std = @import("std");

pub fn SharedSlice(comptime T: type) type {
    return struct {
        const Self = @This();

        const Control = struct {
            ref_count: std.atomic.Value(usize),
            allocator: std.mem.Allocator,
            value: []const T,
        };

        ctrl: *Control,

        pub fn create(
            allocator: std.mem.Allocator,
            value: []const T,
        ) !Self {
            const ctrl = try allocator.create(Control);
            ctrl.* = .{
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
                .value = value,
            };

            return .{ .ctrl = ctrl };
        }

        pub fn retain(self: *const Self) void {
            _ = self.ctrl.ref_count.fetchAdd(1, .seq_cst);
        }

        pub fn get(self: *const Self) []const T {
            return self.ctrl.value;
        }

        pub fn release(self: *const Self) void {
            if (self.ctrl.ref_count.fetchSub(1, .seq_cst) == 1) {
                self.ctrl.allocator.free(self.ctrl.value);
                self.ctrl.allocator.destroy(self.ctrl);
            }
        }
    };
}
