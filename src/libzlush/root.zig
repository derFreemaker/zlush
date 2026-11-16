const std = @import("std");

pub const Zlush = @import("Zlush.zig");

test {
    _ = @import("builder/PlanBuilder.zig");

    _ = @import("common/CircBuffer.zig");
    _ = @import("common/IndexedPriorityQueue.zig");
    _ = @import("common/MultiReaderCircBuffer.zig");
    _ = @import("common/SparseSet.zig");
    _ = @import("common/StableList.zig");

    // _ = @import("Tokenizer.zig");
    _ = @import("Engine.zig");

    @setEvalBranchQuota(1_000_000);
    refAllDeclsRecursive(@This());
}

/// Given a type, recursively references all the declarations inside,
/// so that the semantic analyzer sees them.
/// For deep types, you may use `@setEvalBranchQuota`.
pub fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct",
                .@"enum",
                .@"union",
                .@"opaque",
                => refAllDeclsRecursive(@field(T, decl.name)),

                else => {},
            }
        }
        _ = &@field(T, decl.name);

        // @compileLog(decl, @field(T, decl.name), T);
    }
}
