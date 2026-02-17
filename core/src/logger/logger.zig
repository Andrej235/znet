const std = @import("std");
const Queue = @import("../utils/mpmc_queue.zig").Queue;

const LogLevel = std.log.Level;

pub const log_level: LogLevel = std.options.log_level;
pub const logger_type = @import("../options.zig").options.logger_type;

pub const Logger = if (logger_type == .async) AsyncLogger else SyncLogger;

const log = if (logger_type == .async) asyncLog else std.log.log;

fn asyncLog(
    comptime message_level: LogLevel,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    _ = format;
    _ = args;
}

const AsyncLogger = struct {
    fn scoped(comptime scope: @Type(.enum_literal)) type {
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
};

const SyncLogger = struct {
    fn scoped(comptime scope: @Type(.enum_literal)) type {
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
};

fn ScopedSyncLogger(comptime scope: @Type(.enum_literal)) type {
    return struct {
        /// Log an error message. This log level is intended to be used
        /// when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @branchHint(.cold);
            log(.err, scope, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.warn, scope, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.info, scope, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.debug, scope, format, args);
        }
    };
}

fn ScopedAsyncLogger(comptime scope: @Type(.enum_literal)) type {
    _ = scope;

    return struct {
        /// Log an error message. This log level is intended to be used
        /// when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            @branchHint(.cold);
            _ = format;
            _ = args;
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            _ = format;
            _ = args;
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            _ = format;
            _ = args;
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            _ = format;
            _ = args;
        }
    };
}
