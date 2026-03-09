const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{
        z.Scope(
            null,
            .{
                z.Action(null, healthCheck, .{}),
                z.Action(.echo, echo, .{}),
            },
            .{
                .default_action_executor = .io,
            },
        ),
        z.Scope(.user, .{
            z.Action(.register, helloWorld, .{}),
            z.Action(.login, helloWorld, .{}),
            z.Scope(.me, .{
                z.Action(null, hello, .{}),
                z.Action(.@"{a}/{b}", helloPath, .{}),
                z.Action(.details, hello, .{}),
                z.Action(.@"details/profile_pic", hello, .{}),
                z.Action(.settings, hello, .{}),
            }, .{}),
        }, .{}),
    },
    .{
        .di = .{
            .services = &.{
                .transient(MyService),
                .transient(OtherService),
                .transient(ServiceWithDeps),
            },
        },
    },
);

const MyService = struct {
    pub fn init() MyService {
        return MyService{};
    }

    pub fn doSomething(self: *const MyService) u32 {
        _ = self;
        return 42;
    }
};

const OtherService = struct {
    pub fn init() OtherService {
        return OtherService{};
    }

    pub fn doSomething(self: *const OtherService) u32 {
        _ = self;
        return 24;
    }
};

const ServiceWithDeps = struct {
    other_service: MyService,

    pub fn init(other_service: MyService) ServiceWithDeps {
        return ServiceWithDeps{
            .other_service = other_service,
        };
    }

    pub fn doSomething(self: *const ServiceWithDeps) u32 {
        return self.other_service.doSomething() + 123;
    }
};

pub fn main() !void {
    try App.DIContainer.?.call(helloDI);

    const call_table = comptime App.compileServerCallTable();
    for (call_table) |scope| {
        for (scope) |action| {
            std.debug.print("{s}\n", .{action.path});
        }
    }

    const app: App = .{};
    _ = app;
}

fn hello() !bool {
    std.debug.print("Hello from the handler!\n", .{});
    return true;
}

fn helloPath(
    x: z.Path(struct {
        a: u32,
        b: []const u8,
    }),
) !bool {
    _ = x;
    return true;
}

fn helloDI(
    my_service: ServiceWithDeps,
) !void {
    std.debug.print("Hello from DI! MyService returned: {d}\n", .{my_service.doSomething()});
}

fn echo(msg: z.Body([]const u8)) []const u8 {
    return msg.value;
}

fn helloWorld() !bool {
    std.debug.print("Hello, world!\n", .{});
    return true;
}

fn healthCheck() !bool {
    return true;
}
