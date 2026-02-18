const root = @import("root");

const LoggerType = enum {
    sync,
    async,
};

pub const Options = struct {
    logger_type: LoggerType = .sync,
    async_logger_buffer_size: usize = 1024 * 64, // 64kb
};

/// zNet-wide options that can be overridden by the root file.
pub const options: Options = if (@hasDecl(root, "znet_options")) root.znet_options else .{};
