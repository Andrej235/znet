const std = @import("std");

const App = @import("app.zig").App;

const Errors = error{
    NetworkFailure,
    Timeout,
    Unknown,
};

pub fn main() !void {
    _ = try App(.client).run();
}
