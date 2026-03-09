pub const SingletonService = struct {
    type: type,
    instance_pointer: *anyopaque,

    pub fn resolve(comptime self: SingletonService) self.type {
        return @ptrCast(self.instance_pointer);
    }
};
