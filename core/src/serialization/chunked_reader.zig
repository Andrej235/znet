const std = @import("std");
const Reader = std.io.Reader;

pub const ChunkedReader = struct {
    interface: std.io.Reader,
    consumed_bytes: usize = 0,

    fn stream(r: *Reader, w: *std.io.Writer, limit: std.io.Limit) Reader.StreamError!usize {
        _ = r;
        _ = w;
        _ = limit;
        return Reader.StreamError.EndOfStream;
    }

    fn discard(r: *Reader, limit: std.io.Limit) Reader.Error!usize {
        _ = r;
        _ = limit;
        return Reader.Error.EndOfStream;
    }

    fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
        _ = data;

        const self: *ChunkedReader = @alignCast(@fieldParentPtr("interface", r));
        if (r.seek >= r.end) {
            const size_line_end = getLineEnd(r.buffer, self.consumed_bytes) orelse return Reader.Error.EndOfStream;

            const chunk_size_str = r.buffer[self.consumed_bytes .. size_line_end - 2]; // -2 to exclude the \r\n
            const chunk_size = std.fmt.parseInt(usize, chunk_size_str, 16) catch return Reader.Error.ReadFailed;

            if (chunk_size == 0) {
                return Reader.Error.EndOfStream;
            }

            self.consumed_bytes = size_line_end + chunk_size + 2; // +2 to skip the trailing \r\n after the chunk data
            r.seek = size_line_end;
            r.end = self.consumed_bytes - 2; // don't let the interface touch the trailing \r\n of the chunk
        }

        return 0;
    }

    fn rebase(r: *Reader, capacity: usize) Reader.RebaseError!void {
        _ = r;
        _ = capacity;
        return Reader.RebaseError.EndOfStream;
    }

    pub fn init(reader: *Reader) ChunkedReader {
        return ChunkedReader{
            .interface = .{
                .end = 0,
                .seek = 0,
                .buffer = reader.buffer,
                .vtable = &.{
                    .stream = stream,
                    .discard = discard,
                    .readVec = readVec,
                    .rebase = rebase,
                },
            },
        };
    }

    fn getLineEnd(buffer: []const u8, start: usize) ?usize {
        if (start >= buffer.len) return null;

        for (buffer[start..], 1..) |c, i| {
            if (c == '\r' and buffer[start + i] == '\n') return start + i + 1;
        }
        return null;
    }
};
