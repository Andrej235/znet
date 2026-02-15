const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const znet = b.dependency("znet", .{
        .target = target,
        .optimize = optimize,
    });
    const znet_module = znet.module("znet");

    const test_step = b.step("test", "Run all tests");

    // Open the tests directory
    const src_dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch unreachable;
    var it = src_dir.iterate();

    while (it.next() catch unreachable) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const path = b.pathJoin(&.{ "src", entry.name });

        const test_exe = b.addTest(.{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path(path),
                    .target = target,
                    .optimize = optimize,
                },
            ),
        });
        test_exe.root_module.addImport("znet", znet_module);
        test_step.dependOn(&b.addRunArtifact(test_exe).step);
    }
}
