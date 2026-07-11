const std = @import("std");
const builtin = @import("builtin");

pub const tracy_impl = @import("tracy_impl");

pub fn main(init: std.process.Init) !u8 {
    _ = init; // autofix

    return 1;
}

test {
    _ = std.testing.refAllDecls(@This());

    return error.SkipZigTest;
}
