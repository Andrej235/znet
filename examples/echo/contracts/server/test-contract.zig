const std = @import("std");
const znet = @import("znet");

pub const TestContract = struct {
    pub fn add(ctx: *znet.Context, a: i32) AddErrors!i32 {
        var s = ctx.clients.others() catch return error.FailedToNotify;
        s.broadcast() catch {};

        if (a > 5)
            return error.ValOver5;

        return a;
    }
};

pub const AddErrors = error{
    ValOver5,
    FailedToNotify,
};
