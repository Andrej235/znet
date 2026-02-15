const std = @import("std");
const BuildOptions = @import("build_options.zig").BuildOptions;

// todo: fix memory leaks in setup, right now no memory is freed after build
// this is most likely not a big deal since build runs once and exits, but still not ideal
// especially for many step processes where this **may** run multiple times
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
            .root_source_file = b.path(options.client_main),
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

    //#region codegen
    const contracts = try @import("explore_contracts.zig").ExploreContracts();
    const codegen_module = b.createModule(
        .{
            .root_source_file = b.path("./.zig-cache/znet/znet_contract_registry.zig"),
            .target = options.target,
            .optimize = options.optimize,
        },
    );

    const contract_modules: []*std.Build.Module = try std.heap.page_allocator.alloc(*std.Build.Module, contracts.len);
    for (contracts, 0..) |contract, i| {
        const name = contract.module_name;
        const mod = b.addModule(name, .{
            .root_source_file = b.path(contract.import_path),
        });
        contract_modules[i] = mod;

        codegen_module.addImport(
            name,
            mod,
        );

        mod.addImport("znet", znet_module);
        client_exe.root_module.addImport(name, mod);
        server_exe.root_module.addImport(name, mod);
    }

    for (contract_modules, 0..) |mod_i, i| {
        for (contract_modules, 0..) |mod_j, j| {
            mod_i.addImport(contracts[j].module_name, mod_j);
            mod_j.addImport(contracts[i].module_name, mod_i);
        }
    }

    // znet requires codegen to be imported as "znet_contract_registry"
    znet_module.addImport("znet_contract_registry", codegen_module);
    //#endregion
}

const Role = enum(u8) {
    client,
    server,
};

pub fn pascalToSnakeLower(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    if (input.len == 0) return out.toOwnedSlice(allocator);

    for (input, 0..) |c, i| {
        const is_upper = c >= 'A' and c <= 'Z';
        const is_lower = c >= 'a' and c <= 'z';
        const is_digit = c >= '0' and c <= '9';

        if (i > 0 and is_upper) {
            const prev = input[i - 1];
            const prev_is_lower = prev >= 'a' and prev <= 'z';
            const prev_is_digit = prev >= '0' and prev <= '9';

            // Insert underscore on word boundary
            if (prev_is_lower or prev_is_digit) {
                try out.append(allocator, '_');
            }
        }

        if (is_upper) {
            try out.append(allocator, c + 32); // to lowercase
        } else if (is_lower or is_digit) {
            try out.append(allocator, c);
        } else {
            // optional: keep other chars as-is or error
            try out.append(allocator, c);
        }
    }

    return out.toOwnedSlice(allocator);
}
