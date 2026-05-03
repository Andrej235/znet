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

    pub fn iterator(self: RouteMethodBitmap) BitmapIterator {
        return BitmapIterator{ .bitmap = self.bitmap };
    }

    pub fn toString(self: RouteMethodBitmap, writer: *std.io.Writer) !void {
        var first = true;
        var iter = self.iterator();

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
        const zero_bits = @ctz(self.bitmap);
        if (zero_bits >= http.Method.count)
            return null;

        const method: http.Method = @enumFromInt(zero_bits);
        // clear the bit we just returned
        // int cast is required to avoid overflow as clz of u16 can be 16, which is out of range for a u4 required to shift a u16
        // this is safe from overflow because of the check above ensuring zero_bits is less than the number of methods (which is equal to 9)
        self.bitmap &= ~(@as(u16, 1) << @intCast(zero_bits));
        return method;
    }
};
