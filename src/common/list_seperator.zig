const std = @import("std");

const ListSeperator = @This();

sep: []const u8,
first: bool = true,

pub fn print(self: *ListSeperator, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.first) {
        self.first = false;
        return;
    }

    try w.writeAll(self.sep);
}
