const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var step = b.step("run", "Run the hello world server");
    var exe = b.addExecutable(.{
        .name = "hello_world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const znet = b.dependency("znet", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("znet", znet.module("znet"));

    step.dependOn(&b.addRunArtifact(exe).step);
}
