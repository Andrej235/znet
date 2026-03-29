const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{},
    .{
        .di = .{
            .services = &.{
                .scoped(SomeService),
                .scoped(Service1),
                .scoped(Service2),
                .scoped(Service3),
            },
        },
    },
);

const SomeService = struct {
    s: *Service1,
    s3: *Service3,

    pub fn init(s: *Service1, s3: *Service3) SomeService {
        return SomeService{
            .s = s,
            .s3 = s3,
        };
    }

    pub fn hello(self: *const SomeService, message: z.Body([]const u8)) void {
        _ = .{ message.value, self.s.get(), self.s3.get() };
    }
};

const Service1 = struct {
    s2: *Service2,
    s3: *Service3,

    pub fn init(s2: *Service2, s3: *Service3) Service1 {
        return Service1{
            .s2 = s2,
            .s3 = s3,
        };
    }

    pub fn get(self: *const Service1) u32 {
        return 42 + self.s2.get() + self.s3.get();
    }
};

const Service2 = struct {
    pub fn init() Service2 {
        return Service2{};
    }

    pub fn get(_: *const Service2) u32 {
        return 24;
    }
};

const Service3 = struct {
    s2: *Service2,

    pub fn init(s2: *Service2) Service3 {
        return Service3{
            .s2 = s2,
        };
    }

    pub fn get(self: *const Service3) u32 {
        return 123 + self.s2.get();
    }
};

pub fn main() !void {
    if (App.DIContainer) |di| {
        const TFnScope = comptime di.FunctionScope(echo);

        inline for (@typeInfo(@typeInfo(TFnScope).@"struct".fields[0].type).@"struct".fields) |field| {
            std.debug.print("{}\n", .{@typeInfo(field.type).@"struct".fields[0].type});
        }

        std.debug.print("--- slice --\n", .{});

        const TSliceScope = comptime di.SliceScope(&[_]type{SomeService});

        inline for (@typeInfo(@typeInfo(TSliceScope).@"struct".fields[0].type).@"struct".fields) |field| {
            std.debug.print("{}\n", .{@typeInfo(field.type).@"struct".fields[0].type});
        }

        std.debug.print("--- walk --\n", .{});

        const deps = di.walkDependencyGraph(@TypeOf(echo));
        inline for (deps) |T| {
            std.debug.print("{}\n", .{T});
        }

        // di.call(helloDI, &scope);
    }
}

pub fn echo(_: *SomeService) void {}
