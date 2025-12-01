const std = @import("std");
const common = @import("common");
const UGF8 = common.Unicode.UGF8;

const Tokenizer = @import("tokenizer.zig");

const Zlush = @This();

allocator: std.mem.Allocator,

sw: *common.Stopwatch,

pub fn init(allocator: std.mem.Allocator, sw: *common.Stopwatch) error{OutOfMemory}!Zlush {
    try sw.begin("initialize zlush");
    defer sw.end();

    return Zlush{
        .allocator = allocator,

        .sw = sw,
    };
}

pub fn execute(self: *Zlush, buf: UGF8.Buffer) error{OutOfMemory}!u32 {
    var argv: [256][]const u8 = undefined;
    var len: u32 = 0;

    var tokenizer = Tokenizer.init(buf);
    while (tokenizer.next()) |token| {
        argv[len] = token;
        len += 1;
    }
    
    var child = std.process.Child.init(argv[0..len], self.allocator);
    child.spawn() catch unreachable;
    const term = child.wait() catch unreachable;

    return switch (term) {
        .Exited => |e| e,
        .Signal => |s| s,
        .Stopped => |s| s,
        .Unknown => |u| u,
    };
}

test {
    @setEvalBranchQuota(2_000_000);
    _ = std.testing.refAllDeclsRecursive(@This());
}
