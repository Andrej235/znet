const std = @import("std");

pub const BufferPool = struct {
    // pool
    buffers: [][]u8 = undefined,

    // list of free buffer indices
    free: []u32 = undefined,
    free_count: usize = 0,

    mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        pool_size: usize,
        buffer_size: usize,
    ) !BufferPool {
        const free_stack = try allocator.alloc(u32, pool_size);

        const buffers = try allocator.alloc([]u8, pool_size);
        for (buffers, 0..) |*buf, i| {
            free_stack[i] = @intCast(i);
            buf.* = try allocator.alloc(u8, buffer_size);
        }

        return .{
            .buffers = buffers,
            .free = free_stack,
            .free_count = pool_size,
        };
    }

    pub fn deinit(self: *BufferPool, allocator: std.mem.Allocator) void {
        for (self.buffers) |buf| {
            allocator.free(buf);
        }
        allocator.free(self.buffers);
        allocator.free(self.free);
    }

    /// Acquire a buffer index
    /// Returns null if exhausted
    pub fn acquire(self: *BufferPool) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_count == 0) {
            return null;
        }

        self.free_count -= 1;
        return self.free[self.free_count];
    }

    /// Release a buffer index back to the pool
    pub fn release(self: *BufferPool, idx: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.free[self.free_count] = idx;
        self.free_count += 1;
    }

    pub fn buffer(self: *BufferPool, idx: u32) []u8 {
        return self.buffers[idx][0..];
    }
};
