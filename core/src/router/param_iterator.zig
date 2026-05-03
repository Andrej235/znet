const std = @import("std");

pub const ParamIterator = struct {
    request_path: []const u8,
    template_path: []const u8,

    request_path_index: usize,
    template_path_index: usize,

    /// Both paths must be normalized (no leading or trailing slash, no duplicate slashes, etc.) before being passed to the iterator
    pub fn init(request_path: []const u8, template_path: []const u8) ParamIterator {
        return ParamIterator{
            .request_path = if (std.mem.indexOfScalar(u8, request_path, '?')) |query_start| request_path[0..query_start] else request_path,
            .request_path_index = 0,

            .template_path = template_path,
            .template_path_index = 0,
        };
    }

    pub fn next(self: *ParamIterator) ?struct { name: []const u8, value: []const u8 } {
        while (true) {
            self.template_path_index = (std.mem.indexOfScalarPos(u8, self.template_path, self.template_path_index, '/') orelse return null) + 1;
            self.request_path_index = (std.mem.indexOfScalarPos(u8, self.request_path, self.request_path_index, '/') orelse return null) + 1;

            if (self.template_path[self.template_path_index] != '{') // not a param segment
                continue;

            const request_template_path_end_index = std.mem.indexOfScalarPos(u8, self.template_path, self.template_path_index, '/') orelse self.template_path.len;
            const request_path_end_index = std.mem.indexOfScalarPos(u8, self.request_path, self.request_path_index, '/') orelse self.request_path.len;

            const param_name = self.template_path[self.template_path_index + 1 .. request_template_path_end_index - 1]; // remove { and }
            const param_value = self.request_path[self.request_path_index..request_path_end_index];

            self.template_path_index = request_template_path_end_index;
            self.request_path_index = request_path_end_index;

            return .{
                .name = param_name,
                .value = param_value,
            };
        }

        return null;
    }
};
