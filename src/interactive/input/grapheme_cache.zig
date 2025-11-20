const std = @import("std");

const Grapheme = @import("input_token.zig").InputToken.Grapheme;

const GraphemeCache = @This();

buf: []u8,

idx: usize = 0,

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!GraphemeCache {
    return GraphemeCache{
        .buf = try allocator.alloc(u8, 16 * 1024),
    };
}

pub fn deinit(self: *GraphemeCache, allocator: std.mem.Allocator) void {
    allocator.free(self.buf);
}

pub fn put(self: *GraphemeCache, data: []const u8) []const u8 {
    if (self.idx + data.len > self.buf.len) self.idx = 0;
    defer self.idx += data.len;

    const buffered = self.buf[self.idx .. self.idx + data.len];
    @memcpy(buffered, data);

    return buffered;
}
