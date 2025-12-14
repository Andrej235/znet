const std = @import("std");
const App = @import("app.zig").App;

pub fn main() !void {
    try App(.server).run();
}
