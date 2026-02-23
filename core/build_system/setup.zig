const std = @import("std");
const builtin = @import("builtin");
const BuildOptions = @import("build_options.zig").BuildOptions;

pub fn setupZnet(b: *std.Build, options: BuildOptions) !void {
    const znet = b.dependency("znet", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const znet_module = znet.module("znet");
    znet_module.link_libc = if (builtin.os.tag == .windows) true else false;

    const run_step = b.step("run", "Run the client app");

    //#region client exe
    const client_step = b.step("client", "Run the client app");
    const client_exe = b.addExecutable(.{
        .name = options.exe_name.client,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.client_main),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = if (builtin.os.tag == .windows) true else false,
        }),
    });

    b.installArtifact(client_exe);
    client_step.dependOn(run_step);
    const client_run_cmd = b.addRunArtifact(client_exe);
    client_step.dependOn(&client_run_cmd.step);
    client_run_cmd.step.dependOn(b.getInstallStep());

    client_exe.root_module.addImport("znet", znet_module);
    const client_options = b.addOptions();
    client_options.addOption(Role, "role", .client);
    client_exe.root_module.addOptions("znet/role", client_options);

    client_exe.root_module.addIncludePath(b.path("src"));
    //#endregion

    //#region server exe
    const server_step = b.step("server", "Run the server");
    const server_exe = b.addExecutable(.{
        .name = options.exe_name.server,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.server_main),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });

    b.installArtifact(server_exe);
    server_step.dependOn(run_step);
    const server_cmd = b.addRunArtifact(server_exe);
    server_step.dependOn(&server_cmd.step);
    server_cmd.step.dependOn(b.getInstallStep());

    server_exe.root_module.addImport("znet", znet_module);
    const server_options = b.addOptions();
    server_options.addOption(Role, "role", .server);
    server_exe.root_module.addOptions("znet/role", server_options);

    server_exe.root_module.addIncludePath(b.path("src"));
    //#endregion
}

const Role = enum(u8) {
    client,
    server,
};
