const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const role_option = b.option(
        []const u8,
        "role",
        "Build role: client or server",
    ) orelse "";

    const role = if (std.mem.eql(u8, role_option, "server"))
        @import("src/role.zig").Role.server
    else
        @import("src/role.zig").Role.client;
    @import("src/role.zig").running_as = role;

    _ = b.addModule("znet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = if (role == .server) "znet-server" else "znet-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path(if (role == .server) "src/server-main.zig" else "src/client-main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    _ = try @import("build-system/explore-contracts.zig").ExploreContracts();
    exe.root_module.addImport("generated", b.createModule(
        .{
            .root_source_file = b.path("./.zig-cache/zNet/test.zig"),
            .target = target,
            .optimize = optimize,
        },
    ));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
