const std = @import("std");

pub const manifest: @import("manifest.zig") = @import("zon");

const _GapBuffer = @import("gap_buffer.zig");

pub const GrowStrategie = union(enum) {
    fixed: usize,
    multiply: usize,
    custom: *const fn (cur_len: usize, n: usize) usize,

    pub inline fn calculate(self: GrowStrategie, cur_len: usize, n: usize) usize {
        return switch (self) {
            .fixed => |f| {
                var added_len = f;
                while (added_len < n) {
                    added_len += f;
                }

                return cur_len + added_len;
            },
            .multiply => |m| {
                if (m == 0 or m == 1) {
                    @compileError(std.fmt.comptimePrint("invalid multiply factor: {}", .{m}));
                }

                var added_len = cur_len * m;
                while (added_len < n) {
                    added_len *= m;
                }

                return cur_len + added_len;
            },
            .custom => |c| {
                const new_len = c(cur_len, n);
                if (new_len < cur_len + n) {
                    @branchHint(.cold);
                    std.debug.panic("calculated lower length than needed: {}", .{new_len});
                }

                return new_len;
            },
        };
    }
};

pub const GapBufferConfig = _GapBuffer.GapBufferConfig;
pub const GapBuffer = _GapBuffer.GapBuffer;

pub const gwidth = @import("gwidth.zig");

test {
    @setEvalBranchQuota(2_000_000);
    _ = std.testing.refAllDeclsRecursive(@This());
}
