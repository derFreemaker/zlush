const std = @import("std");
const common = @import("common");

const Zlush = @This();

// pub fn execute(command: []const common.unicode.UGF8.Unit) u32 {
//     
// }

test {
    @setEvalBranchQuota(2_000_000);
    _ = std.testing.refAllDeclsRecursive(@This());
}
