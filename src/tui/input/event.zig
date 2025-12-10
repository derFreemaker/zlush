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
    paste: UGF8.Buffer,
};
