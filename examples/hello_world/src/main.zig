const std = @import("std");
const z = @import("znet");

const App = z.App(
    .{},
    .{
        .di = .{
            .services = &.{
                .scoped(MyService),
                .transient(ServiceWithDeps),
            },
        },
    },
);

const MyService = struct {
    pub fn init() MyService {
        std.debug.print("MyService init\n", .{});
        return MyService{};
    }

    pub fn doSomething(self: *const MyService) u32 {
        _ = self;
        return 42;
    }
};

const ServiceWithDeps = struct {
    other_service: *const MyService,

    pub fn init(other_service: *const MyService) ServiceWithDeps {
        std.debug.print("ServiceWithDeps init\n", .{});

        return ServiceWithDeps{
            .other_service = other_service,
        };
    }

    pub fn doSomething(self: *const ServiceWithDeps) u32 {
        return self.other_service.doSomething() + 123;
    }
};

pub fn main() !void {
    if (App.DIContainer) |di| {
        const TScope = comptime di.FunctionScope(helloDI);
        var scope: TScope = undefined;
        di.call(helloDI, &scope);
    }
}

fn helloDI(service: *MyService, serviceWithDeps: *ServiceWithDeps) void {
    std.debug.print("Hello from DI! Service value: {}, ServiceWithDeps value: {}\n", .{ service.doSomething(), serviceWithDeps.doSomething() });
}
