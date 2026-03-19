const std = @import("std");
const z = @import("znet");

const SomeService = struct {
    s: Service1,
    s3: Service3,

    pub fn init(s: Service1, s3: Service3) SomeService {
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
    s2: Service2,
    s3: Service3,

    pub fn init(s2: Service2, s3: Service3) Service1 {
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
    s2: Service2,

    pub fn init(s2: Service2) Service3 {
        return Service3{
            .s2 = s2,
        };
    }

    pub fn get(self: *const Service3) u32 {
        return 123 + self.s2.get();
    }
};

pub fn echo(message: z.Body([]const u8), service: SomeService) []const u8 {
    service.hello(message);
    return message.value;
}

pub const App = z.App(
    .{z.Scope(
        .echo,
        .{
            z.Action(null, echo, .{}),
        },
        .{
            .di = z.DIC{
                .services = &[_]z.DIService{
                    .transient(SomeService),
                    .transient(Service1),
                    .transient(Service2),
                    .transient(Service3),
                },
            },
        },
    )},
    .{
        .default_action_executor = .worker_pool,
    },
);
