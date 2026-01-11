const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const znet = b.dependency("znet", .{
        .target = target,
        .optimize = optimize,
    });
    const znet_module = znet.module("znet");

    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });
    const zbench_module = zbench.module("zbench");

    const bench_step = b.step("bench", "Run all benchmarks");

    // Open the benchmarks directory
    const src_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    var it = src_dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "bench.zig")) continue;

        const path = b.pathJoin(&.{ "src", entry.name });

        const bench_exe = b.addExecutable(.{
            .name = entry.name,
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path(path),
                    .target = target,
                    .optimize = optimize,
                },
            ),
        });
        bench_exe.root_module.addImport("znet", znet_module);
        bench_exe.root_module.addImport("zbench", zbench_module);
        bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
    }
}
