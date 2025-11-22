const std = @import("std");

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

pub fn get(self: *GraphemeCache, n: usize) []u8 {
    if (self.idx + n > self.buf.len) self.idx = 0;
    defer self.idx += n;

    return self.buf[self.idx .. self.idx + n];
}
