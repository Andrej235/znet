const std = @import("std");

const options = @import("../options.zig").options;
const Logger = @import("logger.zig").Logger;

const header_size = @sizeOf(usize);
const buffer_size = options.async_logger_buffer_size;
var buffer: [buffer_size]u8 = undefined; // layout: [message size (usize)][message bytes]...

var head: usize = 0;
var tail: usize = 0;
var free_space: usize = buffer_size;

var mutex: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};

var thread: ?std.Thread = null;
var state: std.atomic.Value(ShutdownState) = .init(.running);
var initialized: std.atomic.Value(bool) = .init(false);

const WriteErrors = error{NotEnoughSpace};
const RingBufferWriter = std.io.GenericWriter(void, WriteErrors, write);
var writer: RingBufferWriter = .{ .context = {} };

fn write(_: void, bytes: []const u8) WriteErrors!usize {
    if (bytes.len > free_space) {
        return WriteErrors.NotEnoughSpace;
    }

    if (tail + bytes.len < buffer_size) {
        // no need to wrap around the buffer
        @memcpy(buffer[tail .. tail + bytes.len], bytes);
    } else {
        // need to wrap around the buffer
        const first_part_size = buffer_size - tail;
        const second_part_size = bytes.len - first_part_size;

        @memcpy(buffer[tail..], bytes[0..first_part_size]);
        @memcpy(buffer[0..second_part_size], bytes[first_part_size..]);
    }

    tail = (tail + bytes.len) % buffer_size;
    free_space -= bytes.len;
    return bytes.len;
}

const ShutdownState = enum(u8) {
    running,
    graceful,
    immediate,
};

pub const ShutdownMode = enum {
    graceful,
    immediate,
};

pub fn start() !void {
    if (thread != null) return error.ThreadAlreadyStarted;

    free_space = buffer_size;
    state.store(.running, .release);
    thread = try std.Thread.spawn(.{}, threadFn, .{});
    thread.?.setName("logger") catch |err| {
        Logger.err("Failed to set async logger thread name: {}", .{err});
    };

    while (!initialized.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
}

pub fn stop(mode: ShutdownMode) !void {
    if (state.load(.acquire) != .running) return error.ThreadNotRunning;

    state.store(switch (mode) {
        .graceful => .graceful,
        .immediate => .immediate,
    }, .release);

    cond.signal();
    thread.?.join();
    thread = null;
}

fn threadFn() void {
    initialized.store(true, .release);

    while (true) {
        const buffers = getOldestLog() catch break orelse continue;

        var write_buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&write_buffer);
        defer std.debug.unlockStderrWriter();

        nosuspend stderr.writeAll(buffers.first_part) catch return;
        if (buffers.second_part) |part| {
            nosuspend stderr.writeAll(part) catch return;
        }

        // lock to release the buffer space after writing the log message
        mutex.lock();
        defer mutex.unlock();
        const n = header_size + buffers.msg_len;
        free_space += n;
        head = (head + n) % buffer_size;
    }
}

fn getOldestLog() !?struct { first_part: []u8, second_part: ?[]u8, msg_len: usize } {
    mutex.lock();
    defer mutex.unlock();

    while (free_space > buffer_size - header_size and state.load(.acquire) == .running) {
        cond.wait(&mutex);
    }

    const curr_state = state.load(.acquire);
    if (curr_state == .immediate or (curr_state == .graceful and free_space > buffer_size - header_size)) {
        return error.ThreadStopped; // no more logs to process, exit the thread
    }

    const msg_len = len: {
        if (head + header_size < buffer_size) {
            const len_bytes = buffer[head..][0..header_size];
            break :len std.mem.readInt(usize, len_bytes, .big);
        } else {
            const first_part_size = buffer_size - head;
            const second_part_size = header_size - first_part_size;

            var len_bytes: [header_size]u8 = undefined;
            @memcpy(len_bytes[0..first_part_size], buffer[head..]);
            @memcpy(len_bytes[first_part_size..], buffer[0..second_part_size]);
            break :len std.mem.readInt(usize, &len_bytes, .big);
        }
    };

    if (free_space > buffer_size - header_size - msg_len) {
        // missing or corrupted message
        return null;
    }

    var first_part: []u8 = undefined;
    var second_part: ?[]u8 = null;

    if (head + header_size < buffer_size - msg_len) { // is there enough memory after the header for the whole message?
        first_part = buffer[head + header_size .. head + header_size + msg_len];
    } else if (head + header_size < buffer_size) { // is there at least some memory after the header for the message?
        const first_part_size = buffer_size - head - header_size;
        const second_part_size = msg_len - first_part_size;

        first_part = buffer[head + header_size .. head + header_size + first_part_size];
        second_part = buffer[0..second_part_size];
    } else { // header wrapped or there is exactly 0 bytes after it, read only from the start
        first_part = buffer[head + header_size - buffer_size .. head + header_size - buffer_size + msg_len];
    }

    return .{
        .first_part = first_part,
        .second_part = second_part,
        .msg_len = msg_len,
    };
}

pub fn addLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    mutex.lock();
    defer mutex.unlock();

    if (free_space <= header_size) {
        // no free space, drop the log message
        return;
    }

    const level_txt = comptime message_level.asText();
    const prefix2 = comptime if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const fmt = comptime level_txt ++ prefix2 ++ format ++ "\n";

    const msg_len = std.fmt.count(fmt, args);
    if (msg_len + header_size > free_space) {
        // not enough free space, drop the log message
        return;
    }

    _ = writer.writeInt(usize, msg_len, .big) catch return;
    _ = writer.print(fmt, args) catch {
        // should never happen since we already checked the free space
        return;
    };

    cond.signal();
}
