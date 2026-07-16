const std = @import("std");

const Zlush = @This();

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Zlush {
    return Zlush{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Zlush) void {
    _ = self; // autofix
}

test {
    _ = std.testing.refAllDecls(@This());

    return error.SkipZigTest;
}
