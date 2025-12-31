const std = @import("std");

const Queue = @import("../utils/mpmc-queue.zig").Queue;
const Job = @import("job.zig").Job;
const HandlerFn = @import("../handler-fn/handler-fn.zig").HandlerFn;
const deserializeMessageHeaders = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;

pub const Worker = struct {
    job_queue: *Queue(Job),
    call_table: []const []const HandlerFn,
    allocator: std.mem.Allocator,
    response_buffer: []u8,

    pub fn init(
        job_queue: *Queue(Job),
        call_table: []const []const HandlerFn,
        allocator: std.mem.Allocator,
    ) !Worker {
        return .{
            .job_queue = job_queue,
            .call_table = call_table,
            .allocator = allocator,
            .response_buffer = try allocator.alloc(u8, 1024),
        };
    }

    pub fn run(self: *Worker) !noreturn {
        while (true) {
            const job = self.job_queue.pop();
            var reader: std.Io.Reader = .fixed(job.data);

            const header = try deserializeMessageHeaders(&reader);

            switch (header) {
                .Request => |req_header| {
                    const handler = self.call_table[req_header.contract_id][req_header.method_id];

                    var writer: std.Io.Writer = .fixed(self.response_buffer);
                    try handler(header.Request, self.allocator, &reader, &writer);

                    const response_payload_len = std.mem.readInt(u32, self.response_buffer[6..10], .big);
                    std.debug.print("handler result [{} | gen {}]: {any}\n", .{ job.client_id.index, job.client_id.gen, self.response_buffer[0 .. response_payload_len + 10] });
                },
                .Response => {
                    return error.UnexpectedResponseHeader;
                },
            }
        }
    }
};
