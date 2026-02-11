const std = @import("std");

const PendingRequest = @import("pending_request.zig").PendingRequest;

pub const PendingRequestsMap = struct {
    allocator: std.mem.Allocator,

    map: std.AutoHashMap(u32, PendingRequest),
    current_request_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) PendingRequestsMap {
        return PendingRequestsMap{
            .allocator = allocator,
            .map = std.AutoHashMap(u32, PendingRequest).init(allocator),
        };
    }

    pub fn deinit(self: *PendingRequestsMap) void {
        self.clear() catch {};
        self.map.deinit();
    }

    pub fn clear(self: *PendingRequestsMap) !void {
        var it = self.map.iterator();
        while (it.next()) |pending_request|
            try pending_request.value_ptr.destroy(pending_request.value_ptr.promise);

        self.map.clearRetainingCapacity();
    }

    pub fn insert(self: *PendingRequestsMap, pending_request: PendingRequest) !u32 {
        self.current_request_id += 1;
        try self.map.put(self.current_request_id, pending_request);
        return self.current_request_id;
    }

    pub fn pop(self: *PendingRequestsMap, request_id: u32) !PendingRequest {
        if (self.map.get(request_id)) |pending_request| {
            _ = self.map.remove(request_id);
            return pending_request;
        }

        return error.NotFound;
    }
};
