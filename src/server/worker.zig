const std = @import("std");

const Queue = @import("../utils/mpmc-queue.zig").Queue;
const Job = @import("job.zig").Job;
const JobResult = @import("job-result.zig").JobResult;

const HandlerFn = @import("../handler-fn/handler-fn.zig").HandlerFn;
const deserializeMessageHeaders = @import("../message-headers/deserialize-message-headers.zig").deserializeMessageHeaders;

pub const Worker = struct {
    job_queue: *Queue(Job),
    job_result_queue: *Queue(JobResult),
    wakeup_fd: std.posix.fd_t,

    call_table: []const []const HandlerFn,
    allocator: std.mem.Allocator,
    response_buffer: []u8,

    pub fn init(
        job_queue: *Queue(Job),
        job_result_queue: *Queue(JobResult),
        call_table: []const []const HandlerFn,
        wakeup_fd: std.posix.fd_t,
        allocator: std.mem.Allocator,
    ) !Worker {
        return .{
            .job_queue = job_queue,
            .job_result_queue = job_result_queue,
            .wakeup_fd = wakeup_fd,

            .call_table = call_table,
            .allocator = allocator,
            .response_buffer = try allocator.alloc(u8, 1024),
        };
    }

    pub fn run(self: *Worker) !noreturn {
        while (true) {
            const job = self.job_queue.pop();
            var reader: std.Io.Reader = .fixed(job.data);

            const headers = try deserializeMessageHeaders(&reader);
            std.debug.print("responding to {}\n", .{headers.Request.request_id});

            switch (headers) {
                .Request => |req_header| {
                    const handler = self.call_table[req_header.contract_id][req_header.method_id];

                    var writer: std.Io.Writer = .fixed(self.response_buffer);
                    try handler(headers.Request, self.allocator, &reader, &writer);

                    const response_payload_len = std.mem.readInt(u32, self.response_buffer[6..10], .big);
                    const response_data = try self.allocator.alloc(u8, response_payload_len + 10);
                    @memcpy(response_data, self.response_buffer[0..response_data.len]);

                    const job_result = JobResult{
                        .client_id = job.client_id,
                        .data = response_data,
                    };
                    self.job_result_queue.push(job_result);
                    // Note: response_data will be freed by the server after sending

                    // notify the reactor thread that a new job result is available
                    _ = try std.posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));
                },
                .Response => {
                    return error.UnexpectedResponseHeader;
                },
            }
        }
    }
};
