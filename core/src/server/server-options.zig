pub const ServerOptions = struct {
    max_clients: u32 = 1024,
    worker_threads: u8 = 8,
    max_jobs_in_queue: u32 = 128,
    job_result_buffer_size: usize = 1024,
    client_read_buffer_size: usize = 4096,
};
