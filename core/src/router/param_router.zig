const std = @import("std");

pub const ParamIterator = struct {
    request_path: []const u8,
    request_template_path: []const u8,

    request_path_index: usize,
    request_template_path_index: usize,

    pub fn next(self: *ParamIterator) ?struct { name: []const u8, value: []const u8 } {
        while (true) {
            self.request_template_path_index = (std.mem.indexOfScalarPos(u8, self.request_template_path, self.request_template_path_index, '/') orelse return null) + 1;
            self.request_path_index = (std.mem.indexOfScalarPos(u8, self.request_path, self.request_path_index, '/') orelse return null) + 1;

            if (self.request_template_path[self.request_template_path_index] != '{') // not a param segment
                continue;

            const request_template_path_end_index = std.mem.indexOfScalarPos(u8, self.request_template_path, self.request_template_path_index, '/') orelse self.request_template_path.len;
            const request_path_end_index = std.mem.indexOfScalarPos(u8, self.request_path, self.request_path_index, '/') orelse self.request_path.len;

            const param_name = self.request_template_path[self.request_template_path_index + 1 .. request_template_path_end_index - 1]; // remove { and }
            const param_value = self.request_path[self.request_path_index..request_path_end_index];

            self.request_template_path_index = request_template_path_end_index;
            self.request_path_index = request_path_end_index;

            return .{
                .name = param_name,
                .value = param_value,
            };
        }

        return null;
    }
};
