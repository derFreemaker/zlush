const std = @import("std");

const ListSeperator = @import("list_seperator.zig");

pub const CSI: []const u8 = "\x1b[";

pub const TextLayer = enum(u1) {
    foreground,
    background,

    pub fn modifier(self: TextLayer) u8 {
        return switch (self) {
            .foreground => 0,
            .background => 10,
        };
    }
};

pub const Style = enum(u8) {
    bold = 1,
    dim,
    italic,
    underline,
    blink,

    reverse = 7,
    hidden,
    strikethrough,
};

pub const Color = union(enum) {
    c8: Colors8,
    b8: u8,
    rgb8: RGB,

    pub fn normal(c8: Colors8) Color {
        return Color{ .c8 = c8 };
    }

    pub fn bit8(n: u8) Color {
        return Color{ .b8 = n };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return Color{ .rgb8 = .{
            .r = r,
            .g = g,
            .b = b,
        } };
    }

    fn printArg(self: Color, buf: []u8, layer: TextLayer) []const u8 {
        switch (self) {
            .c8 => |c8| {
                std.debug.assert(buf.len >= 2);
                return std.fmt.bufPrint(buf, "{d}", .{@intFromEnum(c8) + layer.modifier()}) catch unreachable;
            },
            .b8 => |n| {
                std.debug.assert(buf.len >= 8);
                return std.fmt.bufPrint(buf, "{d};5;{d}", .{ 38 + layer.modifier(), n }) catch unreachable;
            },
            .rgb8 => |rgb8| {
                std.debug.assert(buf.len >= 16);
                return std.fmt.bufPrint(buf, "{d};2;{d};{d};{d}", .{ 38 + layer.modifier(), rgb8.r, rgb8.g, rgb8.b }) catch unreachable;
            },
        }
    }

    pub fn print(self: Color, buf: []u8, layer: TextLayer) []const u8 {
        std.debug.assert(buf.len >= 3);
        return std.fmt.bufPrint(buf, CSI ++ "{d}m", .{self.printArg(layer, buf[3..])});
    }

    pub const Colors8 = enum(u7) {
        default = 39,

        black = 30,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,

        bright_black = 90,
        bright_red,
        bright_green,
        bright_yellow,
        bright_blue,
        bright_magenta,
        bright_cyan,
        bright_white,
    };

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };
};

pub const Coloring = struct {
    inherit_existing_coloring: bool = false,

    foreground: ?Color = null,
    background: ?Color = null,
    style: ?Style = null,

    pub fn format(self: Coloring, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!self.inherit_existing_coloring) {
            try w.writeAll(comptime reset());
        }

        try w.writeAll(CSI);
        var sep: ListSeperator = .{ .sep = ";" };

        if (self.style) |style| {
            try sep.print(w);

            try w.print("{d}", .{@intFromEnum(style)});
        }

        if (self.foreground) |fg| {
            try sep.print(w);

            var buf: [16]u8 = undefined;
            try w.writeAll(fg.printArg(&buf, .foreground));
        }

        if (self.background) |bg| {
            try sep.print(w);

            var buf: [16]u8 = undefined;
            try w.writeAll(bg.printArg(&buf, .background));
        }

        try w.writeByte('m');
    }
};

pub fn reset() []const u8 {
    return CSI ++ "0m";
}
