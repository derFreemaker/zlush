const std = @import("std");

const Zlush = @This();

// pub fn execute(command: []const u8) u32 {
// 
// }

test {
    @setEvalBranchQuota(2_000_000);
    _ = std.testing.refAllDeclsRecursive(@This());
}
