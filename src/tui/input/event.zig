const std = @import("std");
const common = @import("common");
const UGF8 = common.Unicode.UGF8;

const Key = @import("key.zig");
const Mouse = @import("mouse.zig");
const Winsize = @import("winsize.zig");

pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,

    mouse: Mouse,
    mouse_leave,

    focus_in,
    focus_out,

    winsize: Winsize,
    paste: Paste,

    pub const Paste = struct {
        alloc: std.mem.Allocator,
        buf: UGF8.Buffer,

        pub inline fn deinit(self: *Paste) void {
            self.buf.deinit(self.alloc);
        }
    };
};
