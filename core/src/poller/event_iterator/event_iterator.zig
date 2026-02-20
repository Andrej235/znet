const std = @import("std");
const builtin = @import("builtin");

const LinuxEventIterator = @import("linux_event_iterator.zig").LinuxEventIterator;

const Self = @This();

impl: Impl = undefined,

const Impl = if (builtin.os.tag == .linux) LinuxEventIterator else @compileError("Unsupported OS");
