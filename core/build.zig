const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("znet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // _ = try @import("build-system/explore-contracts.zig").ExploreContracts();
    // exe.root_module.addImport("generated", b.createModule(
    //     .{
    //         .root_source_file = b.path("./.zig-cache/zNet/test.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //     },
    // ));
}

pub const setup = @import("build-system/setup.zig").setupZnet;
