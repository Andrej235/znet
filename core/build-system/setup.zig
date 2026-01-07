const std = @import("std");

const BuildOptions = @import("build-options.zig").BuildOptions;

pub fn setupZnet(b: *std.Build, options: BuildOptions) !void {
    const znet = b.dependency("znet", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const znet_module = znet.module("znet");

    const run_step = b.step("run", "Run the client app");

    //#region client exe
    const client_step = b.step("client", "Run the client app");
    const client_exe = b.addExecutable(.{
        .name = options.exe_name.client,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = options.target,
            .optimize = options.optimize,
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
    //#endregion

    //#region server exe
    const server_step = b.step("server", "Run the server");
    const server_exe = b.addExecutable(.{
        .name = options.exe_name.server,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
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
    //#endregion
}

const Role = enum(u8) {
    client,
    server,
};
