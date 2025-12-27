const zNet = @import("zNet");
const std = @import("std");
const testing = std.testing;

test "server start" {
    const server = zNet.Server(.{ .contracts = &.{TestContract} }).start(std.heap.page_allocator);

    var input_fixed_buffer: [1024]u8 = undefined;
    var input_stream = std.io.fixedBufferStream(&input_fixed_buffer);
    const input_reader = input_stream.reader();
    const input_writer = input_stream.writer();

    var output_fixed_buffer: [1024]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_fixed_buffer);
    const output_reader = output_stream.reader();
    const output_writer = output_stream.writer();

    try zNet.serializeMessageHeader(input_writer, .{
        .Request = .{
            .version = 1,
            .msg_type = .Request,
            .request_id = 1,
            .contract_id = 0,
            .method_id = 1,
            .payload_len = 0,
        },
    });

    try zNet.Serializer.serialize(u8, input_writer.any(), @as(u8, 3));
    try zNet.Serializer.serialize(u16, input_writer.any(), @as(u16, 5));
    input_stream.reset();

    server.call(input_reader.any(), output_writer.any()) catch |err| {
        std.debug.print("Error calling handler: {}\n", .{err});
    };

    var deserializer = zNet.Deserializer.init(std.heap.page_allocator);
    output_stream.reset();

    const result = try deserializer.deserialize(output_reader.any(), @typeInfo(@TypeOf(TestContract.anotherFunction)).@"fn".return_type.?);
    try testing.expectEqual(result, 8);
}

const TestContract = struct {
    pub fn testFunction(x: i32) !i32 {
        return 123 * x;
    }

    pub fn anotherFunction(x: u8, y: u16) i32 {
        std.debug.print("{}, {}\n", .{ x, y });
        return @as(i32, x) + @as(i32, y);
    }
};
