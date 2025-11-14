const std = @import("std");

pub const InputToken = union(enum) {
    invalid: void,

    char: Char,
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

    pub fn deinit(self: *InputToken) void {
        switch (self.*) {
            .grapheme => |*g| g.deinit(),
            else => {},
        }
    }
    
    pub fn dw(self: InputToken) i4 {
        return switch (self) {
            .char => |c| c.dw,
            .grapheme => |g| g.dw,
            else => 0,
        };
    }
    
    pub const Char = struct {
        buf: [4]u8,
        len: u3,
        dw: i4,

        pub fn get(self: Char) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub const Grapheme = struct {
        allocator: std.mem.Allocator,
        data: []const u8,
        dw: i4,

        pub fn deinit(self: *Grapheme) void {
            self.allocator.free(self.data);
        }
    };
};
