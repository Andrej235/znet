const std = @import("std");
const http = @import("../http/http.zig");

pub const RouteMethodBitmap = struct {
    bitmap: u16,

    pub fn init(initial: u16) RouteMethodBitmap {
        return RouteMethodBitmap{
            .bitmap = initial,
        };
    }

    pub fn hasMethod(self: RouteMethodBitmap, method: http.Method) bool {
        return (self.bitmap & (@as(u16, 1) << @intFromEnum(method))) != 0;
    }

    pub fn addMethod(self: *RouteMethodBitmap, method: http.Method) void {
        self.bitmap |= @as(u16, 1) << @intFromEnum(method);
    }

    pub fn removeMethod(self: *RouteMethodBitmap, method: http.Method) void {
        self.bitmap &= ~(@as(u16, 1) << @intFromEnum(method));
    }

    pub fn clear(self: *RouteMethodBitmap) void {
        self.bitmap = 0;
    }

    pub fn toString(self: RouteMethodBitmap, writer: *std.io.Writer) !void {
        var first = true;
        var iter = BitmapIterator{ .bitmap = self.bitmap };

        while (iter.next()) |method| {
            if (!first) {
                _ = try writer.write(", ");
            }
            _ = try writer.write(method.toString());
            first = false;
        }
    }
};

const BitmapIterator = struct {
    bitmap: u16,

    pub fn next(self: *BitmapIterator) ?http.Method {
        const zero_bits = @clz(self.bitmap);
        if (zero_bits >= http.Method.count)
            return null;

        const method: http.Method = @enumFromInt(zero_bits);
        self.bitmap &= ~(@as(u16, 1) << zero_bits); // clear the bit we just returned
        return method;
    }
};
