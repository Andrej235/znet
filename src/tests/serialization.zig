const std = @import("std");
const zNet = @import("zNet");
const testing = std.testing;

// var stdout_buffer: [256]u8 = undefined;
//     var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
//     const stdout = &stdout_writer.interface;
//     try stdout.flush();

pub const Vector = struct {
    x: f32,
    y: f32,
    z: f32,
};

const TestStruct = struct {
    a: i32,
    b: []const u8,
    c: Vector,
};

const BigStruct = struct {
    test_struct: TestStruct,
    numbers: [10]u64,
    vectors: [5]Vector,
};

const Weekday = enum(u8) {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
};

const DayType = enum(u8) {
    Weekday = 1,
    Weekend = 2,
    Holiday = 4,
    Workday = 8,
};

test "int s/d" {
    try testing.expectEqual(12345, roundTrip(comptime_int, 12345));

    try testing.expectEqual(12345, roundTrip(i32, 12345));
    try testing.expectEqual(123456789, roundTrip(i32, 123456789));
    try testing.expectEqual(123456789123, roundTrip(i64, 123456789123));
    try testing.expectEqual(123456789123, roundTrip(i72, 123456789123));
    try testing.expectEqual(123456789123456789, roundTrip(i64, 123456789123456789));
    try testing.expectEqual(123456789123456789123456789123456789123456789123456789123456789, roundTrip(i256, 123456789123456789123456789123456789123456789123456789123456789));

    try testing.expectEqual(12345, roundTrip(u32, 12345));
    try testing.expectEqual(123456789, roundTrip(u32, 123456789));
    try testing.expectEqual(123456789123, roundTrip(u64, 123456789123));
    try testing.expectEqual(123456789123456789, roundTrip(u64, 123456789123456789));
    try testing.expectEqual(123456789123456789123456789123456789123456789123456789123456789, roundTrip(u256, 123456789123456789123456789123456789123456789123456789123456789));
}

test "float s/d" {
    // TODO: comptime float loses precision
    try testing.expectEqual(12345, roundTrip(comptime_float, 12345));
    // try testing.expectEqual(0.000000000001, roundTrip(comptime_float, 0.000000000001));
    // try testing.expectEqual(123.0001231248, roundTrip(comptime_float, 123.0001231248));
    // try testing.expectEqual(12345.6789, roundTrip(comptime_float, 12345));

    try testing.expectEqual(12345, roundTrip(f32, 12345));
    try testing.expectEqual(0.1, roundTrip(f16, 0.1));
    try testing.expectEqual(0.01, roundTrip(f16, 0.01));
    try testing.expectEqual(123.5, roundTrip(f16, 123.5));

    try testing.expectEqual(12345, roundTrip(f32, 12345));
    try testing.expectEqual(1234567, roundTrip(f32, 1234567));
    try testing.expectEqual(0.1, roundTrip(f32, 0.1));
    try testing.expectEqual(0.01, roundTrip(f32, 0.01));
    try testing.expectEqual(0.001, roundTrip(f32, 0.001));
    try testing.expectEqual(0.000000000001, roundTrip(f32, 0.000000000001));
    try testing.expectEqual(123.123456789, roundTrip(f32, 123.123456789));

    try testing.expectEqual(123456789, roundTrip(f64, 123456789));
    try testing.expectEqual(0.1, roundTrip(f64, 0.1));
    try testing.expectEqual(0.01, roundTrip(f64, 0.01));
    try testing.expectEqual(0.000000000001, roundTrip(f64, 0.000000000001));
    try testing.expectEqual(123.123456789, roundTrip(f64, 123.123456789));

    try testing.expectEqual(12345678912345, roundTrip(f128, 12345678912345));
    try testing.expectEqual(0.1, roundTrip(f128, 0.1));
    try testing.expectEqual(0.01, roundTrip(f128, 0.01));
    try testing.expectEqual(0.000000000001, roundTrip(f128, 0.000000000001));
    try testing.expectEqual(123.123456789, roundTrip(f128, 123.123456789));
}

test "struct s/d" {
    try testing.expectEqualDeep(
        Vector{ .x = 123, .y = 12.534, .z = 5934.123 },
        roundTripInfer(Vector{ .x = 123, .y = 12.534, .z = 5934.123 }),
    );

    try testing.expectEqualDeep(
        TestStruct{ .a = 12345, .b = "Hello, Zig!", .c = Vector{ .x = 1.23, .y = 4.56, .z = 7.89 } },
        roundTripInfer(TestStruct{ .a = 12345, .b = "Hello, Zig!", .c = Vector{ .x = 1.23, .y = 4.56, .z = 7.89 } }),
    );
}

test "array s/d" {
    try testing.expectEqualDeep(
        [_]i32{ 1, 2, 3, 4, 5 },
        roundTripInfer([5]i32{ 1, 2, 3, 4, 5 }),
    );

    try testing.expectEqualDeep(
        [_]Vector{
            .{ .x = 1.1, .y = 2.2, .z = 3.3 },
            .{ .x = 4.4, .y = 5.5, .z = 6.6 },
            .{ .x = 7.7, .y = 8.8, .z = 9.9 },
        },
        roundTripInfer([3]Vector{
            .{ .x = 1.1, .y = 2.2, .z = 3.3 },
            .{ .x = 4.4, .y = 5.5, .z = 6.6 },
            .{ .x = 7.7, .y = 8.8, .z = 9.9 },
        }),
    );

    try testing.expectEqualDeep(
        [_][]const u8{
            "Hello",
            "from",
            "Zig",
            "array",
            "serialization",
        },
        roundTripInfer([5][]const u8{
            "Hello",
            "from",
            "Zig",
            "array",
            "serialization",
        }),
    );

    try testing.expectEqualDeep(
        [_][3]f32{
            .{ 1.1, 2.2, 3.3 },
            .{ 4.4, 5.5, 6.6 },
            .{ 7.7, 8.8, 9.9 },
        },
        roundTripInfer([3][3]f32{
            .{ 1.1, 2.2, 3.3 },
            .{ 4.4, 5.5, 6.6 },
            .{ 7.7, 8.8, 9.9 },
        }),
    );

    try testing.expectEqualDeep([_]TestStruct{
        .{ .a = 1, .b = "first", .c = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 } },
        .{ .a = 2, .b = "second", .c = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 } },
        .{ .a = 3, .b = "third", .c = Vector{ .x = 7.7, .y = 8.8, .z = 9.9 } },
    }, roundTripInfer([3]TestStruct{
        .{ .a = 1, .b = "first", .c = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 } },
        .{ .a = 2, .b = "second", .c = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 } },
        .{ .a = 3, .b = "third", .c = Vector{ .x = 7.7, .y = 8.8, .z = 9.9 } },
    }));

    try testing.expectEqualDeep(
        [_][3]TestStruct{
            .{
                .{ .a = 1, .b = "a", .c = Vector{ .x = 0.1, .y = 0.2, .z = 0.3 } },
                .{ .a = 2, .b = "b", .c = Vector{ .x = 1.1, .y = 1.2, .z = 1.3 } },
                .{ .a = 3, .b = "c", .c = Vector{ .x = 2.1, .y = 2.2, .z = 2.3 } },
            },
            .{
                .{ .a = 4, .b = "d", .c = Vector{ .x = 3.1, .y = 3.2, .z = 3.3 } },
                .{ .a = 5, .b = "e", .c = Vector{ .x = 4.1, .y = 4.2, .z = 4.3 } },
                .{ .a = 6, .b = "f", .c = Vector{ .x = 5.1, .y = 5.2, .z = 5.3 } },
            },
            .{
                .{ .a = 7, .b = "g", .c = Vector{ .x = 6.1, .y = 6.2, .z = 6.3 } },
                .{ .a = 8, .b = "h", .c = Vector{ .x = 7.1, .y = 7.2, .z = 7.3 } },
                .{ .a = 9, .b = "i", .c = Vector{ .x = 8.1, .y = 8.2, .z = 8.3 } },
            },
        },
        roundTripInfer([3][3]TestStruct{
            .{
                .{ .a = 1, .b = "a", .c = Vector{ .x = 0.1, .y = 0.2, .z = 0.3 } },
                .{ .a = 2, .b = "b", .c = Vector{ .x = 1.1, .y = 1.2, .z = 1.3 } },
                .{ .a = 3, .b = "c", .c = Vector{ .x = 2.1, .y = 2.2, .z = 2.3 } },
            },
            .{
                .{ .a = 4, .b = "d", .c = Vector{ .x = 3.1, .y = 3.2, .z = 3.3 } },
                .{ .a = 5, .b = "e", .c = Vector{ .x = 4.1, .y = 4.2, .z = 4.3 } },
                .{ .a = 6, .b = "f", .c = Vector{ .x = 5.1, .y = 5.2, .z = 5.3 } },
            },
            .{
                .{ .a = 7, .b = "g", .c = Vector{ .x = 6.1, .y = 6.2, .z = 6.3 } },
                .{ .a = 8, .b = "h", .c = Vector{ .x = 7.1, .y = 7.2, .z = 7.3 } },
                .{ .a = 9, .b = "i", .c = Vector{ .x = 8.1, .y = 8.2, .z = 8.3 } },
            },
        }),
    );
}

test "slices s/d" {
    const str: []const u8 = "Hello, Zig!";
    try testing.expectEqualStrings(
        str,
        roundTripInfer(str),
    );

    const str_empty: []const u8 = "";
    try testing.expectEqualStrings(
        str_empty,
        roundTripInfer(str_empty),
    );

    const str_w_sentinel: [:0]const u8 = "Hello, Zig!";
    try testing.expectEqualStrings(
        str_w_sentinel,
        roundTripInfer(str_w_sentinel),
    );

    const many_ptr_w_sentinel: [:0]const u8 = "Hello, Zig!";
    try testing.expectEqualDeep(
        many_ptr_w_sentinel,
        roundTripInfer(many_ptr_w_sentinel),
    );
    try testing.expectEqualSentinel(
        u8,
        0,
        many_ptr_w_sentinel,
        roundTripInfer(many_ptr_w_sentinel),
    );

    const empty_many_ptr_w_sentinel: [:0]const u8 = "";
    try testing.expectEqualDeep(
        empty_many_ptr_w_sentinel,
        roundTripInfer(empty_many_ptr_w_sentinel),
    );
    try testing.expectEqualSentinel(
        u8,
        0,
        empty_many_ptr_w_sentinel,
        roundTripInfer(empty_many_ptr_w_sentinel),
    );

    const mat = [_][]const u8{
        "This",
        "is",
        "a",
        "test",
        "of",
        "slices",
        "serialization",
    };
    const mat_slice = mat[0..];
    try testing.expectEqualDeep(
        mat_slice,
        roundTripInfer(mat_slice),
    );

    const allocator = std.heap.page_allocator;
    var vecs = try allocator.alloc(Vector, 3);
    vecs[0] = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 };
    vecs[1] = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 };
    vecs[2] = Vector{ .x = 7.7, .y = 8.8, .z = 9.9 };
    try testing.expectEqualDeep(
        vecs,
        roundTrip([]Vector, vecs),
    );

    var structs = try allocator.alloc(TestStruct, 3);
    structs[0] = TestStruct{ .a = 1, .b = "first", .c = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 } };
    structs[1] = TestStruct{ .a = 2, .b = "second", .c = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 } };
    structs[2] = TestStruct{ .a = 3, .b = "third", .c = Vector{ .x = 7.7, .y = 8.8, .z = 9.9 } };
    try testing.expectEqualDeep(
        structs,
        roundTrip([]TestStruct, structs),
    );

    var big_structs = try allocator.alloc(BigStruct, 2);
    big_structs[0] = BigStruct{
        .test_struct = TestStruct{ .a = 1, .b = "first", .c = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 } },
        .numbers = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
        .vectors = [_]Vector{
            Vector{ .x = 1.1, .y = 2.2, .z = 3.3 },
            Vector{ .x = 4.4, .y = 5.5, .z = 6.6 },
            Vector{ .x = 7.7, .y = 8.8, .z = 9.9 },
            Vector{ .x = 10.1, .y = 11.2, .z = 12.3 },
            Vector{ .x = 13.4, .y = 14.5, .z = 15.6 },
        },
    };
    big_structs[1] = BigStruct{
        .test_struct = TestStruct{ .a = 2, .b = "second", .c = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 } },
        .numbers = [_]u64{ 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 },
        .vectors = [_]Vector{
            Vector{ .x = 16.1, .y = 17.2, .z = 18.3 },
            Vector{ .x = 19.4, .y = 20.5, .z = 21.6 },
            Vector{ .x = 22.7, .y = 23.8, .z = 24.9 },
            Vector{ .x = 25.0, .y = 26.1, .z = 27.2 },
            Vector{ .x = 28.3, .y = 29.4, .z = 30.5 },
        },
    };
    try testing.expectEqualDeep(
        big_structs,
        roundTrip([]BigStruct, big_structs),
    );
}

test "optional s/d" {
    try testing.expectEqual(
        null,
        roundTrip(?i32, null),
    );
    try testing.expectEqual(
        12345,
        roundTrip(?i32, 12345),
    );

    try testing.expectEqualDeep(
        null,
        roundTrip(?TestStruct, null),
    );
    try testing.expectEqualDeep(
        TestStruct{ .a = 54321, .b = "optional struct", .c = Vector{ .x = 9.87, .y = 6.54, .z = 3.21 } },
        roundTrip(?TestStruct, TestStruct{ .a = 54321, .b = "optional struct", .c = Vector{ .x = 9.87, .y = 6.54, .z = 3.21 } }),
    );
}

test "bool s/d" {
    try testing.expectEqual(
        true,
        roundTrip(bool, true),
    );
    try testing.expectEqual(
        false,
        roundTrip(bool, false),
    );
}

test "enum s/d" {
    try testing.expectEqual(
        Weekday.Monday,
        roundTrip(Weekday, Weekday.Monday),
    );
    try testing.expectEqual(
        Weekday.Friday,
        roundTrip(Weekday, Weekday.Friday),
    );
    try testing.expectEqual(
        Weekday.Sunday,
        roundTrip(Weekday, Weekday.Sunday),
    );
}

var deserializer = zNet.Deserializer.init(std.heap.page_allocator);

fn roundTrip(comptime T: type, data: T) T {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    const writer = fbs.writer();
    const reader = fbs.reader();

    zNet.Serializer.serialize(T, writer, data) catch unreachable;
    fbs.reset(); // reset position before reading
    const deserialized: T = deserializer.deserialize(reader, T) catch unreachable;
    return deserialized;
}

fn roundTripInfer(comptime data: anytype) @TypeOf(data) {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    const writer = fbs.writer();
    const reader = fbs.reader();

    zNet.Serializer.serialize(@TypeOf(data), writer, data) catch unreachable;
    fbs.reset(); // reset position before reading
    const deserialized: @TypeOf(data) = deserializer.deserialize(reader, @TypeOf(data)) catch unreachable;
    return deserialized;
}
