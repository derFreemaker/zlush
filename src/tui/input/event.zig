const std = @import("std");
const common = @import("common");
const UGF8 = common.Unicode.UGF8;

const Key = @import("key.zig");
const Mouse = @import("mouse.zig");
const Winsize = @import("winsize.zig");
const Color = @import("../style.zig").Color;

pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,

    mouse: Mouse,
    mouse_leave,

    focus_in,
    focus_out,

    winsize: Winsize,
    paste: Paste,
    paste_start,
    paste_end,
    color_scheme: Color.Scheme,
    color_report: Color.Report,

    // these are delivered as discovered terminal capabilities
    cap_kitty_keyboard,
    cap_kitty_graphics,
    cap_rgb,
    cap_sgr_pixels,
    cap_unicode,
    cap_da1,
    cap_color_scheme_updates,
    cap_multi_cursor,
    
    pub const Paste = struct {
        alloc: std.mem.Allocator,
        buf: []UGF8.Unit,

        pub inline fn deinit(self: *Paste) void {
            for (self.buf) |*unit| {
                unit.deinit(self.alloc);
            }
            
            self.alloc.free(self.buf);
        }
    };
};
