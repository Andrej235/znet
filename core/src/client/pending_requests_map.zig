const std = @import("std");

const PendingRequest = @import("pending_request.zig").PendingRequest;

pub const PendingRequestsMap = struct {
    allocator: std.mem.Allocator,

    mutex: std.Thread.Mutex = .{},

    free_count: usize = 0,
    free_request_ids: []u32,

    requests: []?PendingRequest,

    pub fn init(allocator: std.mem.Allocator, max_inflight_requests: usize) !PendingRequestsMap {
        const free_request_ids = try allocator.alloc(u32, max_inflight_requests);
        const requests = try allocator.alloc(?PendingRequest, max_inflight_requests);

        for (free_request_ids, requests, 0..) |*id, *req, idx| {
            id.* = @intCast(idx);
            req.* = null;
        }

        return PendingRequestsMap{
            .allocator = allocator,
            .free_count = max_inflight_requests,
            .free_request_ids = free_request_ids,
            .requests = requests,
        };
    }

    pub fn deinit(self: *PendingRequestsMap) void {
        self.clear() catch {};
        self.allocator.free(self.free_request_ids);
        self.allocator.free(self.requests);
    }

    pub fn clear(self: *PendingRequestsMap) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.requests) |*req| {
            if (req.*) |r|
                try r.destroy(r.promise);
        }

        for (self.free_request_ids, self.requests, 0..) |*id, *req, idx| {
            id.* = @intCast(idx);
            req.* = null;
        }
        self.free_count = self.requests.len;
    }

    pub fn insert(self: *PendingRequestsMap, pending_request: PendingRequest) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_count == 0)
            return error.OutOfMemory;

        self.free_count -= 1;
        const request_id = self.free_request_ids[self.free_count];
        self.requests[request_id] = pending_request;

        return request_id;
    }

    pub fn pop(self: *PendingRequestsMap, request_id: u32) !PendingRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.requests[request_id]) |pending_request| {
            self.requests[request_id] = null;
            self.free_request_ids[self.free_count] = request_id;
            self.free_count += 1;
            return pending_request;
        }

        return error.NotFound;
    }
};
