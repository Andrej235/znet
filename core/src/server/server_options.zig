pub const ServerOptions = struct {
    max_clients: u32 = 1024,
    worker_pool_size_per_io: u8 = 4,
    max_jobs_in_queue: usize = 128,
    job_result_buffer_size: usize = 1024,
    client_read_buffer_size: usize = 4096,
    client_out_message_queue_size: usize = 8,
    max_read_per_tick: usize = 32 * 1024,
    max_write_per_tick: usize = 32 * 1024,
    reactor_thread_count: u32 = 2,
};
