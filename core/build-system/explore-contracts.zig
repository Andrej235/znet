const std = @import("std");

pub fn ExploreContracts() ![]Contract {
    var cache_dir = try getCacheDir();
    defer cache_dir.close();

    var file = try cache_dir.createFile("znet_contract_registry.zig", .{});
    defer file.close();

    const buffer = try std.heap.page_allocator.alloc(u8, 1024);
    var file_writer = file.writer(buffer);
    const writer = &file_writer.interface;
    defer std.heap.page_allocator.free(buffer);

    const contract_dirs = try getContractDirectories();
    const client_dir = contract_dirs.client;
    const server_dir = contract_dirs.server;

    var client_contracts = std.ArrayList(Contract){};
    if (client_dir) |*dir| {
        // todo: implement
        defer @constCast(dir).close();
        _ = try iterateDir(dir.*, &client_contracts, "contracts/client", .client);
    }

    var server_contracts = std.ArrayList(Contract){};
    if (server_dir) |*dir| {
        defer @constCast(dir).close();
        try iterateDir(dir.*, &server_contracts, "contracts/server", .server);

        try writer.writeAll(
            \\pub const server_contracts: []const type = &.{
            \\
        );

        // todo: sort contracts by name to ensure stable output before writing
        for (server_contracts.items) |item| {
            try writer.writeAll(
                try std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "\t@import(\"{s}\").{s},\n",
                    .{ item.module_name, item.contract_name },
                ),
            );
        }

        try writer.writeAll(
            \\};
            \\
        );
        try writer.flush();
    }

    const joint_contracts = try std.heap.page_allocator.alloc(Contract, client_contracts.items.len + server_contracts.items.len);
    @memcpy(joint_contracts[0..client_contracts.items.len], client_contracts.items);
    @memcpy(joint_contracts[client_contracts.items.len..], server_contracts.items);

    return joint_contracts;
}

const Contract = struct {
    import_path: []const u8,
    contract_name: []const u8,
    module_name: []const u8,

    const Kind = enum {
        client,
        server,
    };
};

fn iterateDir(dir: std.fs.Dir, contracts: *std.ArrayList(Contract), current_path: []const u8, contract_kind: Contract.Kind) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            if (!std.mem.endsWith(u8, entry.name, "contract.zig")) continue;

            try contracts.append(std.heap.page_allocator, .{
                .import_path = try std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}/{s}",
                    .{ current_path, entry.name },
                ),
                .contract_name = try kebabToPascalCase(
                    std.heap.page_allocator,
                    entry.name[0 .. entry.name.len - 4], // remove .zig
                ),
                .module_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{
                    if (contract_kind == .client) "client" else "server",
                    entry.name[0 .. entry.name.len - 4], // remove .zig
                }),
            });
        } else if (entry.kind == .directory) {
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();
            try iterateDir(
                sub_dir,
                contracts,
                try std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}/{s}",
                    .{ current_path, entry.name },
                ),
                contract_kind,
            );
        }
    }
}

pub fn kebabToPascalCase(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var capitalize_next = true;

    for (input) |c| {
        if (c == '-') {
            capitalize_next = true;
            continue;
        }

        if (capitalize_next) {
            out.append(allocator, std.ascii.toUpper(c)) catch return error.OutOfMemory;
            capitalize_next = false;
        } else {
            out.append(allocator, c) catch return error.OutOfMemory;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn getCacheDir() !std.fs.Dir {
    const base_cache_dir = try std.fs.cwd().openDir(".zig-cache", .{});

    return base_cache_dir.openDir("znet", .{}) catch |err| {
        if (err == error.FileNotFound) {
            try base_cache_dir.makeDir("znet");
            return base_cache_dir.openDir("znet", .{});
        } else {
            return err;
        }
    };
}

fn getContractDirectories() !struct {
    client: ?std.fs.Dir,
    server: ?std.fs.Dir,
} {
    var contracts_dir = std.fs.cwd().openDir("./contracts", .{}) catch |err| {
        if (err == error.FileNotFound)
            return .{ .client = null, .server = null };

        return err;
    };
    defer contracts_dir.close();

    const client_dir = contracts_dir.openDir("client", .{ .iterate = true }) catch |err| blk: {
        if (err == error.FileNotFound)
            break :blk null;

        return err;
    };

    const server_dir = contracts_dir.openDir("server", .{ .iterate = true }) catch |err| blk: {
        if (err == error.FileNotFound)
            break :blk null;

        return err;
    };

    return .{
        .client = client_dir,
        .server = server_dir,
    };
}
