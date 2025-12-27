const std = @import("std");

pub fn build(b: *std.Build) void {
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

    const znet_module = b.addModule("src", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = if (role == .server) "znet-server" else "znet-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path(if (role == .server) "src/server-main.zig" else "src/client-main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run all tests");

    // Open the tests directory
    const tests_dir = std.fs.cwd().openDir("src/tests", .{ .iterate = true }) catch unreachable;
    var it = tests_dir.iterate();

    while (it.next() catch unreachable) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const path = b.pathJoin(&.{ "src/tests", entry.name });

        const test_exe = b.addTest(.{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path(path),
                    .target = target,
                    .optimize = optimize,
                },
            ),
        });
        test_exe.root_module.addImport("zNet", znet_module);
        test_step.dependOn(&b.addRunArtifact(test_exe).step);
    }
}
