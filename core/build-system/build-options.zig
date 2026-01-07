const std = @import("std");

pub const BuildOptions = struct {
    exe_name: struct {
        client: []const u8,
        server: []const u8,
    } = .{
        .client = "znet_client",
        .server = "znet_server",
    },
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};
