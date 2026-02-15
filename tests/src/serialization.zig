const std = @import("std");
const zNet = @import("znet");
const testing = std.testing;

fn forceRuntimeTuple(comptime tuple: anytype) StripComptimeFromTupleType(@TypeOf(tuple)) {
    return @as(StripComptimeFromTupleType(@TypeOf(tuple)), tuple);
}

fn StripComptimeFromTupleType(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    inline for (info.fields, 0..) |field, idx| {
        fields[idx] = if (!field.is_comptime) field else .{
            .name = field.name,
            .type = field.type,
            .is_comptime = false,
            .alignment = field.alignment,
            .default_value_ptr = null,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .fields = &fields,
            .decls = info.decls,
            .backing_integer = info.backing_integer,
            .is_tuple = info.is_tuple,
            .layout = info.layout,
        },
    });
}

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

const Weekday = enum {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
};

const DayType = enum(u8) {
    Weekday,
    Weekend = 123,
    Holiday,
    Workday = 32,
    _,
};

const TaggedUnion = union(enum) {
    IntValue: i32,
    FloatValue: f32,
    TextValue: []const u8,
};

const TaggedUnionCustomEnumVals = union(enum(u16)) {
    IntValue: i32 = 123,
    FloatValue: f32 = 2,
    TextValue: []const u8 = 6543,
};

const TaggedUnionCustomEnumValsSmall = union(enum(u5)) {
    IntValue: i32 = 3,
    FloatValue: f32 = 2,
    TextValue: []const u8 = 1,
};

const UntaggedUnion = union {
    IntValue: i32,
    FloatValue: f32,
    TextValue: []const u8,
};

const TaggedUnionWithCustomTagType = union(DayType) {
    Weekday: f32,
    Weekend: f128,
    Holiday: Vector,
    Workday: []Vector,
};

const ErrorSetA = error{
    MadeUpError1,
    MadeUpError2,
    MadeUpError3,
};

const ErrorSetB = error{
    MadeUpErrorA,
    MadeUpErrorB,
    MadeUpErrorC,
};

test "int s/d" {
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

    const big_array: [1024]u8 = [_]u8{0} ** 1024;
    try testing.expectEqualDeep(
        big_array,
        roundTripInfer(big_array),
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

    try testing.expectEqual(
        DayType.Weekend,
        roundTrip(DayType, DayType.Weekend),
    );
    try testing.expectEqual(
        DayType.Holiday,
        roundTrip(DayType, DayType.Holiday),
    );
    try testing.expectEqual(
        @as(DayType, @enumFromInt(16)),
        roundTrip(DayType, @as(DayType, @enumFromInt(16))),
    );
}

test "union s/d" {
    try testing.expectEqualDeep(
        TaggedUnion{ .FloatValue = 12345 },
        roundTripInfer(TaggedUnion{ .FloatValue = 12345 }),
    );
    try testing.expectEqualDeep(
        TaggedUnion{ .IntValue = -54321 },
        roundTripInfer(TaggedUnion{ .IntValue = -54321 }),
    );
    try testing.expectEqualDeep(
        TaggedUnion{ .TextValue = "Hello, Union!" },
        roundTripInfer(TaggedUnion{ .TextValue = "Hello, Union!" }),
    );

    try testing.expectEqualDeep(
        TaggedUnionCustomEnumVals{ .FloatValue = 3.14 },
        roundTripInfer(TaggedUnionCustomEnumVals{ .FloatValue = 3.14 }),
    );
    try testing.expectEqualDeep(
        TaggedUnionCustomEnumVals{ .IntValue = -98765 },
        roundTripInfer(TaggedUnionCustomEnumVals{ .IntValue = -98765 }),
    );
    try testing.expectEqualDeep(
        TaggedUnionCustomEnumVals{ .TextValue = "Custom Enum Values!" },
        roundTripInfer(TaggedUnionCustomEnumVals{ .TextValue = "Custom Enum Values!" }),
    );

    try testing.expectEqualDeep(
        TaggedUnionCustomEnumValsSmall{ .FloatValue = 3.14 },
        roundTripInfer(TaggedUnionCustomEnumValsSmall{ .FloatValue = 3.14 }),
    );
    try testing.expectEqualDeep(
        TaggedUnionCustomEnumValsSmall{ .IntValue = -98765 },
        roundTripInfer(TaggedUnionCustomEnumValsSmall{ .IntValue = -98765 }),
    );
    try testing.expectEqualDeep(
        TaggedUnionCustomEnumValsSmall{ .TextValue = "Custom Enum Values!" },
        roundTripInfer(TaggedUnionCustomEnumValsSmall{ .TextValue = "Custom Enum Values!" }),
    );

    try testing.expectEqualDeep(
        TaggedUnionWithCustomTagType{ .Weekday = 5.67 },
        roundTripInfer(TaggedUnionWithCustomTagType{ .Weekday = 5.67 }),
    );
    try testing.expectEqualDeep(
        TaggedUnionWithCustomTagType{ .Weekend = 12345678912345.6789 },
        roundTripInfer(TaggedUnionWithCustomTagType{ .Weekend = 12345678912345.6789 }),
    );
    try testing.expectEqualDeep(
        TaggedUnionWithCustomTagType{ .Holiday = Vector{ .x = 1.23, .y = 4.56, .z = 7.89 } },
        roundTripInfer(TaggedUnionWithCustomTagType{ .Holiday = Vector{ .x = 1.23, .y = 4.56, .z = 7.89 } }),
    );
    const allocator = std.heap.page_allocator;
    var vecs = try allocator.alloc(Vector, 3);
    vecs[0] = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 };
    vecs[1] = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 };
    vecs[2] = Vector{ .x = 7.7, .y = 8.8, .z = 9.9 };
    try testing.expectEqualDeep(
        TaggedUnionWithCustomTagType{ .Workday = vecs },
        roundTrip(TaggedUnionWithCustomTagType, TaggedUnionWithCustomTagType{ .Workday = vecs }),
    );
}

test "error unions s/d" {
    try testing.expectEqual(
        123,
        roundTrip(ErrorSetA!u32, 123),
    );
    try testing.expectEqual(
        ErrorSetA.MadeUpError3,
        roundTrip(ErrorSetA!u32, ErrorSetA.MadeUpError3),
    );
    try testing.expectEqual(
        ErrorSetB.MadeUpErrorB,
        roundTrip(ErrorSetB!u32, ErrorSetB.MadeUpErrorB),
    );

    try testing.expectEqual(
        ErrorSetA.MadeUpError1,
        roundTrip(ErrorSetA!BigStruct, ErrorSetA.MadeUpError1),
    );
    try testing.expectEqual(
        error.MadeUpError2,
        roundTrip(ErrorSetA!BigStruct, error.MadeUpError2),
    );

    try testing.expectEqualDeep(
        BigStruct{
            .test_struct = TestStruct{ .a = 42, .b = "The answer", .c = Vector{ .x = 0.0, .y = 1.1, .z = 2.2 } },
            .numbers = [_]u64{ 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000 },
            .vectors = [_]Vector{
                Vector{ .x = 3.3, .y = 4.4, .z = 5.5 },
                Vector{ .x = 6.6, .y = 7.7, .z = 8.8 },
                Vector{ .x = 9.9, .y = 10.10, .z = 11.11 },
                Vector{ .x = 12.12, .y = 13.13, .z = 14.14 },
                Vector{ .x = 15.15, .y = 16.16, .z = 17.17 },
            },
        },
        roundTrip(ErrorSetA!BigStruct, BigStruct{
            .test_struct = TestStruct{ .a = 42, .b = "The answer", .c = Vector{ .x = 0.0, .y = 1.1, .z = 2.2 } },
            .numbers = [_]u64{ 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000 },
            .vectors = [_]Vector{
                Vector{ .x = 3.3, .y = 4.4, .z = 5.5 },
                Vector{ .x = 6.6, .y = 7.7, .z = 8.8 },
                Vector{ .x = 9.9, .y = 10.10, .z = 11.11 },
                Vector{ .x = 12.12, .y = 13.13, .z = 14.14 },
                Vector{ .x = 15.15, .y = 16.16, .z = 17.17 },
            },
        }),
    );

    const allocator = std.heap.page_allocator;
    var structs = try allocator.alloc(TestStruct, 3);
    structs[0] = TestStruct{ .a = 1, .b = "first", .c = Vector{ .x = 1.1, .y = 2.2, .z = 3.3 } };
    structs[1] = TestStruct{ .a = 2, .b = "second", .c = Vector{ .x = 4.4, .y = 5.5, .z = 6.6 } };
    structs[2] = TestStruct{ .a = 3, .b = "third", .c = Vector{ .x = 7.7, .y = 8.8, .z = 9.9 } };
    try testing.expectEqualDeep(
        structs,
        roundTrip((ErrorSetA || ErrorSetB)![]TestStruct, structs),
    );
}

test "tuples s/d" {
    const empty_tuple = forceRuntimeTuple(.{});
    try testing.expectEqualDeep(
        empty_tuple,
        roundTrip(@TypeOf(empty_tuple), empty_tuple),
    );

    const single_element_tuple = forceRuntimeTuple(.{"single"});
    try testing.expectEqualDeep(
        single_element_tuple,
        roundTrip(@TypeOf(single_element_tuple), single_element_tuple),
    );

    const mixed_tuple = forceRuntimeTuple(.{ "string", @as(i32, 42), @as(f64, 3.14), Vector{ .x = 1.0, .y = 2.0, .z = 3.0 } });
    try testing.expectEqualDeep(
        mixed_tuple,
        roundTrip(@TypeOf(mixed_tuple), mixed_tuple),
    );

    const nested_tuple = forceRuntimeTuple(.{ forceRuntimeTuple(.{ "nested", @as(i32, 1) }), @as(f64, 3.14) });
    try testing.expectEqualDeep(
        nested_tuple,
        roundTrip(@TypeOf(nested_tuple), nested_tuple),
    );

    const large_tuple = forceRuntimeTuple(.{ "string", @as(i32, 1), @as(f64, 2.0), Vector{ .x = 1.0, .y = 2.0, .z = 3.0 }, "another string", @as(i32, 3), @as(f64, 4.0), Vector{ .x = 4.0, .y = 5.0, .z = 6.0 }, "yet another string", @as(i32, 5), @as(f64, 6.0), Vector{ .x = 7.0, .y = 8.0, .z = 9.0 }, "final string", @as(i32, 7), @as(f64, 8.0), Vector{ .x = 10.0, .y = 11.0, .z = 12.0 } });
    try testing.expectEqualDeep(
        large_tuple,
        roundTrip(@TypeOf(large_tuple), large_tuple),
    );

    const optional_tuple = forceRuntimeTuple(.{ "optional", @as(?f64, null), @as(f16, 3.14) });
    try testing.expectEqualDeep(
        optional_tuple,
        roundTrip(@TypeOf(optional_tuple), optional_tuple),
    );

    const bool_tuple = forceRuntimeTuple(.{ "bools", true, false });
    try testing.expectEqualDeep(
        bool_tuple,
        roundTrip(@TypeOf(bool_tuple), bool_tuple),
    );

    const max_elements_tuple = forceRuntimeTuple(.{
        "elem1", "elem2",  "elem3",  "elem4",  "elem5",  "elem6",  "elem7",  "elem8",
        "elem9", "elem10", "elem11", "elem12", "elem13", "elem14", "elem15", "elem16",
    });
    try testing.expectEqualDeep(
        max_elements_tuple,
        roundTrip(@TypeOf(max_elements_tuple), max_elements_tuple),
    );
}

var deserializer = zNet.Deserializer.init(std.heap.page_allocator);

fn roundTrip(comptime T: type, data: T) T {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(&buffer);

    zNet.Serializer.serialize(T, &writer, data) catch unreachable;

    const deserialized: T = if (@typeInfo(T) == .error_union) deserializer.deserialize(&reader, T) catch |err| switch (err) {
        error.InvalidUnionTag => unreachable,
        error.UnexpectedEof => unreachable,
        error.AllocationFailed => unreachable,
        error.EndOfStream => unreachable,
        error.InvalidBooleanValue => unreachable,
        else => {
            return @errorCast(err);
        },
    } else deserializer.deserialize(&reader, T) catch unreachable;
    return deserialized;
}

fn roundTripInfer(comptime data: anytype) @TypeOf(data) {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(&buffer);

    zNet.Serializer.serialize(@TypeOf(data), &writer, data) catch unreachable;
    const deserialized: @TypeOf(data) = deserializer.deserialize(&reader, @TypeOf(data)) catch unreachable;
    return deserialized;
}
