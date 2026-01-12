const std = @import("std");

pub const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    exe_name: struct {
        client: []const u8,
        server: []const u8,
    } = .{
        .client = "znet_client",
        .server = "znet_server",
    },
    client_main: []const u8 = "src/client.zig",
    server_main: []const u8 = "src/server.zig",
};
