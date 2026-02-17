const root = @import("root");

const LoggerType = enum {
    sync,
    async,
};

pub const Options = struct {
    logger_type: LoggerType = .sync,
};

/// zNet-wide options that can be overridden by the root file.
pub const options: Options = if (@hasDecl(root, "znet_options")) root.znet_options else .{};
