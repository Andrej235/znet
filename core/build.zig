const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("znet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");
    const test_exe = b.addTest(.{
        .root_module = b.createModule(
            .{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
            },
        ),
    });
    test_step.dependOn(&b.addRunArtifact(test_exe).step);
}

pub const setup = @import("build_system/setup.zig").setupZnet;
