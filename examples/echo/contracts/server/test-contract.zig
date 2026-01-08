const std = @import("std");
const znet = @import("znet");

pub const TestContract = struct {
    pub fn add(ctx: *znet.Context, a: i32) AddErrors!i32 {
        std.debug.print("{any}\n", .{ctx.clients.sender_id});

        if (a > 5)
            return error.ValOver5;

        return a;
    }
};

pub const AddErrors = error{
    ValOver5,
};
