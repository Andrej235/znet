const std = @import("std");
const z = @import("znet");

const my_config = SomeConfiguration{
    .value = 123,
};

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
                .singleton(&my_config),
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
    other_service: *const MyService,

    pub fn init(other_service: *const MyService) ServiceWithDeps {
        return ServiceWithDeps{
            .other_service = other_service,
        };
    }

    pub fn doSomething(self: *const ServiceWithDeps) u32 {
        return self.other_service.doSomething() + 123;
    }
};

const SomeConfiguration = struct {
    value: u32,
};

pub fn main() !void {
    // try App.DIContainer.?.call(helloDI);
    const config = App.DIContainer.?.resolve(*const SomeConfiguration);
    std.debug.print("Config value: {}\n", .{config.value});

    const service: MyService = App.DIContainer.?.resolve(*const MyService);
    std.debug.print("Service value: {}\n", .{service.doSomething()});

    const serviceWithDeps: ServiceWithDeps = App.DIContainer.?.resolve(*const ServiceWithDeps);
    std.debug.print("ServiceWithDeps value: {}\n", .{serviceWithDeps.doSomething()});

    // const call_table = comptime App.compileServerCallTable();
    // for (call_table) |scope| {
    //     for (scope) |action| {
    //         std.debug.print("{s}\n", .{action.path});
    //     }
    // }

    // const app: App = .{};
    // _ = app;
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
