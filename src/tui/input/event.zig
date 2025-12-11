const std = @import("std");
const common = @import("common");
const UGF = common.Unicode.UGF;

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
        buf: []UGF.Unit,

        pub inline fn deinit(self: *Paste) void {
            for (self.buf) |*unit| {
                unit.deinit(self.alloc);
            }
            
            self.alloc.free(self.buf);
        }
    };
};
