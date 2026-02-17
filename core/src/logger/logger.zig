const std = @import("std");
const Queue = @import("../utils/mpmc_queue.zig").Queue;

const LogLevel = std.log.Level;

pub const log_level: LogLevel = std.options.log_level;
pub const logger_type = @import("../options.zig").options.logger_type;

pub const Logger = if (logger_type == .async) AsyncLogger else SyncLogger;

const AsyncLoggerEventPool = if (logger_type == .async) @import("async_logger_event_pool.zig") else undefined;

inline fn asyncLog(
    comptime message_level: LogLevel,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !std.log.logEnabled(message_level, scope)) return;

    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var msg: [256]u8 = undefined;
    const buf = std.fmt.bufPrint(msg[0..], level_txt ++ prefix2 ++ format ++ "\n", args) catch return;

    AsyncLoggerEventPool.addLog(buf);
}

const AsyncLogger = struct {
    pub fn scoped(comptime scope: @Type(.enum_literal)) type {
        return ScopedAsyncLogger(scope);
    }

    const default_log_scope = .default;

    /// The default scoped logging namespace.
    pub const default = scoped(default_log_scope);

    /// Log an error message using the default scope. This log level is intended to
    /// be used when something has gone wrong. This might be recoverable or might
    /// be followed by the program exiting.
    pub const err = default.err;

    /// Log a warning message using the default scope. This log level is intended
    /// to be used if it is uncertain whether something has gone wrong or not, but
    /// the circumstances would be worth investigating.
    pub const warn = default.warn;

    /// Log an info message using the default scope. This log level is intended to
    /// be used for general messages about the state of the program.
    pub const info = default.info;

    /// Log a debug message using the default scope. This log level is intended to
    /// be used for messages which are only useful for debugging.
    pub const debug = default.debug;

    pub fn startAsyncLogger() !void {
        if (comptime logger_type == .sync) return error.SyncLoggerSelected;

        AsyncLoggerEventPool.init();
        try AsyncLoggerEventPool.startThread();
    }
};

const SyncLogger = struct {
    pub fn scoped(comptime scope: @Type(.enum_literal)) type {
        return ScopedSyncLogger(scope);
    }

    const default_log_scope = .default;

    /// The default scoped logging namespace.
    pub const default = scoped(default_log_scope);

    /// Log an error message using the default scope. This log level is intended to
    /// be used when something has gone wrong. This might be recoverable or might
    /// be followed by the program exiting.
    pub const err = default.err;

    /// Log a warning message using the default scope. This log level is intended
    /// to be used if it is uncertain whether something has gone wrong or not, but
    /// the circumstances would be worth investigating.
    pub const warn = default.warn;

    /// Log an info message using the default scope. This log level is intended to
    /// be used for general messages about the state of the program.
    pub const info = default.info;

    /// Log a debug message using the default scope. This log level is intended to
    /// be used for messages which are only useful for debugging.
    pub const debug = default.debug;

    pub fn startAsyncLogger() !void {
        @compileError("Async logger cannot be started when sync logger is selected, maybe you forgot to set znet_options.logger_type to .async?");
    }
};

fn ScopedSyncLogger(comptime scope: @Type(.enum_literal)) type {
    const std_log = std.log.scoped(scope);

    return struct {
        /// Log an error message using the default scope. This log level is intended to
        /// be used when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub const err = std_log.err;

        /// Log a warning message using the default scope. This log level is intended
        /// to be used if it is uncertain whether something has gone wrong or not, but
        /// the circumstances would be worth investigating.
        pub const warn = std_log.warn;

        /// Log an info message using the default scope. This log level is intended to
        /// be used for general messages about the state of the program.
        pub const info = std_log.info;

        /// Log a debug message using the default scope. This log level is intended to
        /// be used for messages which are only useful for debugging.
        pub const debug = std_log.debug;
    };
}

fn ScopedAsyncLogger(comptime scope: @Type(.enum_literal)) type {
    return struct {
        /// Log an error message. This log level is intended to be used
        /// when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @branchHint(.cold);
            asyncLog(.err, scope, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            asyncLog(.warn, scope, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            asyncLog(.info, scope, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            asyncLog(.debug, scope, format, args);
        }
    };
}
