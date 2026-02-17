const std = @import("std");

const buffer_len = 256;
const buffer_count = 256;
var buffers: [buffer_count]struct {
    data: [buffer_len]u8 = undefined,
    len: usize = 0,
} = undefined;

var free_indices: [buffer_count]usize = undefined;
var free_index_count: usize = 0;

var taken_indices: [buffer_count]usize = undefined;
var taken_index_count: usize = 0;
var taken_head: usize = 0;
var taken_tail: usize = 0;

var mutex: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};

var thread: ?std.Thread = null;
var state: std.atomic.Value(ShutdownState) = .init(.running);
var initialized: std.atomic.Value(bool) = .init(false);

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

    for (0..buffer_count) |i| {
        free_indices[i] = i;
        taken_indices[i] = i;
    }
    free_index_count = buffer_count;

    state.store(.running, .release);
    thread = try std.Thread.spawn(.{}, threadFn, .{});

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
        const idx = getOldestIdx() orelse break;
        const message = buffers[idx].data[0..buffers[idx].len];

        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();
        nosuspend stderr.writeAll(message) catch return;

        releaseIdx(idx);
    }
}

fn getOldestIdx() ?usize {
    mutex.lock();
    defer mutex.unlock();

    while (taken_index_count == 0 and state.load(.acquire) == .running) {
        cond.wait(&mutex);
    }

    const curr_state = state.load(.acquire);
    if (curr_state == .immediate or (curr_state == .graceful and taken_index_count == 0)) {
        return null;
    }

    // take the oldest index from the taken_indices queue
    const index = taken_indices[taken_head];
    taken_head = (taken_head + 1) % taken_indices.len;
    taken_index_count -= 1;

    return index;
}

fn releaseIdx(index: usize) void {
    mutex.lock();
    defer mutex.unlock();

    free_indices[free_index_count] = index;
    free_index_count += 1;
}

pub fn addLog(msg: []u8) void {
    if (msg.len > buffer_len) {
        // message is too long, drop it
        return;
    }

    mutex.lock();
    defer mutex.unlock();

    if (free_index_count == 0) {
        // no free buffers, drop the log message
        return;
    }

    free_index_count -= 1;
    const index = free_indices[free_index_count];

    taken_indices[taken_tail] = index;
    taken_tail = (taken_tail + 1) % taken_indices.len;
    taken_index_count += 1;

    const buffer = &buffers[index];
    @memcpy(buffer.data[0..msg.len], msg);
    buffer.len = msg.len;
    cond.signal();
}
