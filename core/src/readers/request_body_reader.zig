const std = @import("std");
const Reader = std.io.Reader;

const ChunkedReader = @import("chunked_reader.zig").ChunkedReader;

pub const RequestBodyReader = struct {
    interface: *Reader = undefined,

    raw_reader: Reader = undefined,
    chunked_reader: ChunkedReader = undefined,

    pub fn init() RequestBodyReader {
        return RequestBodyReader{};
    }

    pub fn initInterface(self: *RequestBodyReader, body: []const u8, chunked: bool) void {
        self.raw_reader = .fixed(body);
        self.interface = &self.raw_reader;

        if (chunked) {
            self.chunked_reader = ChunkedReader.init(self.interface);
            self.interface = &self.chunked_reader.interface;
        }
    }
};
