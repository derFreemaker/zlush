const std = @import("std");

pub const manifest = @import("zon");

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
                    std.debug.panic("calculated lower length '{}' than needed '{}'", .{ new_len, cur_len + n });
                }

                return new_len;
            },
        };
    }
};

const _GapBuffer = @import("gap_buffer.zig");
pub const GapBufferConfig = _GapBuffer.GapBufferConfig;
pub const GapBuffer = _GapBuffer.GapBuffer;

pub const Unicode = struct {
    pub const CodePoint = @import("unicode/code_point.zig");
    pub const Graphemes = @import("unicode/graphemes.zig");
    pub const DisplayWidth = @import("unicode/display_width.zig");
    
    pub const UGF = @import("unicode/ugf.zig");
    pub const UGF8 = @import("unicode/ugf8.zig");
};

pub const Queue = @import("queue.zig").Queue;

pub const Stopwatch = @import("stopwatch.zig");

pub const Ansi = @import("ansi-escape").ansi;
pub const AnsiColor = @import("ansi_color.zig");
pub const ListSeperator = @import("list_seperator.zig");

test {
    @setEvalBranchQuota(2_000_000);
    _ = std.testing.refAllDeclsRecursive(@This());
}
