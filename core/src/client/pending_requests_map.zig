const std = @import("std");

const PendingRequest = @import("pending_request.zig").PendingRequest;
const Client = @import("client.zig").Client;

pub const PendingRequestsMap = struct {
    allocator: std.mem.Allocator,

    client: *Client,
    mutex: std.Thread.Mutex = .{},

    free_count: usize = 0,
    free_request_ids: []u32,

    requests: []PendingRequest,

    pub fn init(allocator: std.mem.Allocator, max_inflight_requests: usize, client: *Client) !PendingRequestsMap {
        const free_request_ids = try allocator.alloc(u32, max_inflight_requests);
        const requests = try allocator.alloc(PendingRequest, max_inflight_requests);

        for (free_request_ids, requests, 0..) |*id, *req, idx| {
            id.* = @intCast(idx);
            req.* = PendingRequest{
                .idx = @intCast(idx),
                .client = client,
            };
        }

        return PendingRequestsMap{
            .allocator = allocator,
            .client = client,
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
            if (req.state == .fulfilled)
                req.release();
        }

        for (self.free_request_ids, self.requests, 0..) |*id, *req, idx| {
            id.* = @intCast(idx);
            req.* = PendingRequest{
                .idx = @intCast(idx),
                .client = self.client,
            };
        }
        self.free_count = self.requests.len;
    }

    pub fn acquire(self: *PendingRequestsMap) !*PendingRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_count == 0)
            return error.OutOfMemory;

        self.free_count -= 1;
        const request_id = self.free_request_ids[self.free_count];
        const pending_request: *PendingRequest = @constCast(&self.requests[request_id]);

        if (pending_request.state != .free) {
            std.debug.print("acquired request that is not free, request_id: {d}, state: {}\n", .{ request_id, pending_request.state });
            return error.InvalidState;
        }

        pending_request.state = .pending;
        return pending_request;
    }

    pub fn release(self: *PendingRequestsMap, request_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (request_id >= self.requests.len) return error.InvalidRequestId;

        self.free_request_ids[self.free_count] = request_id;
        self.free_count += 1;
    }

    pub fn get(self: *PendingRequestsMap, request_id: u32) !*PendingRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (request_id >= self.requests.len) return error.InvalidRequestId;

        return &self.requests[request_id];
    }
};
