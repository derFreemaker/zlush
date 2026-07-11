const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const zttio = @import("zttio");

const Interactive = @import("interactive/interactive.zig");

pub const panic = std.debug.FullPanic(zlushPanic);

pub var global_tty: ?*zttio.Tty = null;

fn zlushPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (global_tty) |tty| {
        tty.revertTerminal();
    }

    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const tracy_impl = @import("tracy_impl");

pub fn main() !u8 {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();

    var gpa = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{
        .retain_metadata = true,
        .never_unmap = true,
    }){
        .backing_allocator = arena_allocator.allocator(),
    } else void{};
    defer if (builtin.mode == .Debug) if (gpa.deinit() == .leak) @panic("leaks detected");
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else arena_allocator.allocator();

    var sw = try common.Stopwatch.init(allocator);
    defer sw.deinit();

    var interactive = try Interactive.init(allocator, &sw);
    defer interactive.deinit();
    return interactive.loop();
}

test {
    @setEvalBranchQuota(2_000_000);
    _ = std.testing.refAllDeclsRecursive(@This());
}
