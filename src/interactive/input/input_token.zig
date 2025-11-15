const std = @import("std");

pub const InputToken = union(enum) {
    invalid: void,

    grapheme: Grapheme,

    backspace: void,
    tab: void,
    vertical_tab: void,
    enter: void,
    pause: void,
    caps_lock: void,
    escape: void,
    space: void,
    page_up: void,
    page_down: void,
    end: void,
    home: void,
    left: void,
    up: void,
    right: void,
    down: void,
    print_screen: void,
    insert: void,
    delete: void,
    left_meta: void,
    right_meta: void,

    kp_0: void,
    kp_1: void,
    kp_2: void,
    kp_3: void,
    kp_4: void,
    kp_5: void,
    kp_6: void,
    kp_7: void,
    kp_8: void,
    kp_9: void,
    kp_multiply: void,
    kp_add: void,
    kp_separator: void,
    kp_subtract: void,
    kp_decimal: void,
    kp_divide: void,

    f1: void,
    f2: void,
    f3: void,
    f4: void,
    f5: void,
    f6: void,
    f7: void,
    f8: void,
    f9: void,
    f10: void,
    f11: void,
    f12: void,
    f13: void,
    f14: void,
    f15: void,
    f16: void,
    f17: void,
    f18: void,
    f19: void,
    f20: void,
    f21: void,
    f22: void,
    f23: void,
    f24: void,
    num_lock: void,
    scroll_lock: void,
    left_shift: void,
    right_shift: void,
    left_control: void,
    right_control: void,
    left_alt: void,
    right_alt: void,
    mute_volume: void,
    lower_volume: void,
    raise_volume: void,
    media_track_next: void,
    media_track_prev: void,
    media_stop: void,
    media_play_pause: void,

    interrupt: void, // ctrl-c
    EOF: void, // ctrl-d
    bell: void, // ctrl-g
    clearScreen: void, // ctrl-l
    form_feed: void,

    pub const Grapheme = union(enum) {
        single: Single,
        cluster: Cluster,

        pub inline fn get(self: Grapheme) []const u8 {
            return switch (self) {
                .single => |s| s.get(),
                .cluster => |c| c.data,
            };
        }

        pub inline fn lenBytes(self: Grapheme) usize {
            return switch (self) {
                .single => |s| s.len,
                .cluster => |c| c.data.len,
            };
        }

        pub inline fn dw(self: Grapheme) u3 {
            return switch (self) {
                .single => |s| s.dw,
                .cluster => |c| c.dw,
            };
        }

        pub const Single = struct {
            buf: [4]u8,
            len: u3,
            dw: u3,

            pub inline fn get(self: Single) []const u8 {
                return self.buf[0..self.len];
            }
        };

        pub const Cluster = struct {
            data: []const u8,
            dw: u3,
        };
    };
};
