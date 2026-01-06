const std = @import("std");

pub fn ExploreContracts() ![]const u8 {
    var cache_dir = try getCacheDir();
    defer cache_dir.close();

    var file = try cache_dir.createFile("test.zig", .{});
    defer file.close();

    const buffer = try std.heap.page_allocator.alloc(u8, 1024);
    defer std.heap.page_allocator.free(buffer);
    var file_writer = file.writer(buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        \\const std = @import("std");
        \\pub fn run() void {
        \\std.debug.print("Hello from build\n", .{});
        \\}
        \\
        \\pub const TestContract = struct {
        \\    pub fn add(_: *TestContract, a: i32) i32 {
        \\      std.debug.print("Hello from TestContract.add with a={}\n", .{a});
        \\        return a + 1;
        \\    }
        \\};
    );
    try writer.flush();

    const path: []const u8 = "./.zig-cache/zNet/test.zig";
    return path;
}

fn getCacheDir() !std.fs.Dir {
    const base_cache_dir = try std.fs.cwd().openDir(".zig-cache", .{});

    return base_cache_dir.openDir("zNet", .{}) catch |err| {
        if (err == error.FileNotFound) {
            try base_cache_dir.makeDir("zNet");
            return base_cache_dir.openDir("zNet", .{});
        } else {
            return err;
        }
    };
}
