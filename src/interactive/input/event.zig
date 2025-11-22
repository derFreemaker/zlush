const std = @import("std");

pub const Event = union(enum) {
    grapheme: Grapheme,
    winsize: Winsize,

    // special events
    tab: void,
    vertical_tab: void,
    enter: void,
    interrupt: void,
    backspace: void,
    delete: void,
    form_feed: void,
    bell: void,
    EOF: void,
    up: void,
    down: void,
    left: void,
    right: void,
};

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

    pub inline fn dw(self: Grapheme) u8 {
        return switch (self) {
            .single => |s| s.dw,
            .cluster => |c| c.dw,
        };
    }

    pub const Single = struct {
        buf: [4]u8,
        len: u3,
        dw: u4,

        pub inline fn get(self: Single) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub const Cluster = struct {
        data: []const u8,
        dw: u8,
    };
};

pub const Winsize = struct {
    cols: u32,
    rows: u32,
};
