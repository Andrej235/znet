const std = @import("std");

const Queue = @import("../utils/mpmc_queue.zig").Queue;
const Job = @import("job.zig").Job;
const JobResult = @import("job_result.zig").JobResult;

const HandlerFn = @import("handler_fn/handler_fn.zig").HandlerFn;
const MessageHeadersByteSize = @import("../message_headers/message_headers.zig").HeadersByteSize;
const deserializeMessageHeaders = @import("../message_headers/deserialize_message_headers.zig").deserializeMessageHeaders;

const Server = @import("server.zig").Server;

pub const Worker = struct {
    server: *Server,
    allocator: std.mem.Allocator,

    job_queue: *Queue(Job),
    job_result_queue: *Queue(JobResult),
    wakeup_fd: std.posix.fd_t,

    call_table: []const []const HandlerFn,
    response_buffer: []u8,

    pub fn init(comptime response_buffer_size: usize, server: *Server) !Worker {
        return .{
            .server = server,
            .allocator = server.allocator,

            .job_queue = server.job_queue,
            .job_result_queue = server.job_result_queue,
            .wakeup_fd = server.wakeup_fd,

            .call_table = Server.call_table,
            .response_buffer = try server.allocator.alloc(u8, response_buffer_size),
        };
    }

    pub fn deinit(self: *Worker) void {
        self.allocator.free(self.response_buffer);
    }

    pub fn run(self: *Worker) !noreturn {
        while (true) {
            const job = self.job_queue.pop();
            std.debug.print("[{}] Picked up a job\n", .{std.Thread.getCurrentId()});
            var reader: std.Io.Reader = .fixed(job.data);

            const headers = try deserializeMessageHeaders(&reader);

            switch (headers) {
                .Request => |req_header| {
                    const handler = self.call_table[req_header.contract_id][req_header.method_id];

                    var writer: std.Io.Writer = .fixed(self.response_buffer);
                    try handler(
                        self.server,
                        job.client_id.index,
                        headers.Request,
                        self.allocator,
                        &reader,
                        &writer,
                    );

                    const response_payload_len = std.mem.readInt(u32, self.response_buffer[MessageHeadersByteSize.Response - 4 .. MessageHeadersByteSize.Response], .big);
                    const response_data = try self.allocator.alloc(u8, response_payload_len + MessageHeadersByteSize.Response);
                    @memcpy(response_data, self.response_buffer[0..response_data.len]);

                    const job_result = JobResult{
                        .client_id = job.client_id,
                        .data = response_data,
                    };
                    self.job_result_queue.push(job_result);

                    // response_data will be freed by the server after sending
                    // notify the reactor thread that a new job result is available
                    _ = try std.posix.write(self.wakeup_fd, std.mem.asBytes(&@as(u64, 1)));

                    self.allocator.free(job.data);
                },
                .Response => {
                    return error.UnexpectedResponseHeader;
                },
                .Broadcast => {
                    return error.UnexpectedBroadcastHeader;
                },
            }
        }
    }
};
