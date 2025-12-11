const std = @import("std");
const common = @import("common");
const UGF = common.Unicode.UGF;
const UGF8 = common.Unicode.UGF8;

const Winsize = @import("../../tui/input/winsize.zig");

const GapBuffer = UGF8.GapBuffer(.{});

const PromptWriter = @This();

allocator: std.mem.Allocator,

writer: *std.Io.Writer,
identation: u32,
winsize: Vec2,

buf: GapBuffer,
cursor: Vec2,
end: Vec2,

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, identation: u32, winsize: Winsize) PromptWriter {
    return PromptWriter{
        .allocator = allocator,

        .writer = writer,
        .identation = identation,
        .winsize = Vec2{ .x = winsize.cols, .y = winsize.rows },

        .buf = .empty,
        .cursor = Vec2{ .x = identation, .y = 0 },
        .end = Vec2{ .x = identation, .y = 0 },
    };
}

pub fn deinit(self: *PromptWriter) void {
    self.buf.deinit(self.allocator);
}

pub fn redraw(self: *PromptWriter) error{WriteFailed}!void {
    try self.reset();
    try self.draw();
}

pub fn reset(self: *PromptWriter) error{WriteFailed}!void {
    if (self.end.y > 0) {
        if (self.end.y - self.cursor.y > 0) {
            try common.Ansi.cursor.next_line(self.writer, self.end.y - self.cursor.y);
        } else {
            try common.Ansi.cursor.to(self.writer, 0, null);
        }

        while (self.end.y > 0) {
            try common.Ansi.erase.line(self.writer);
            try common.Ansi.cursor.prev_line(self.writer, 1);
            self.end.y -= 1;
        }
    }

    try common.Ansi.cursor.to(self.writer, self.identation, null);
    try common.Ansi.erase.line_end(self.writer);

    self.cursor = Vec2{ .x = self.identation, .y = 0 };
    self.end = Vec2{ .x = self.identation, .y = 0 };
}

pub fn draw(self: *PromptWriter) error{WriteFailed}!void {
    if (self.buf.len() == 0) {
        @branchHint(.cold);
        return;
    }

    try self.writeText(self.buf.units.firstHalf(), self.buf.utf8.firstHalf());
    const cursor_edit_pos = self.cursor;

    try self.writeText(self.buf.units.secondHalf(), self.buf.utf8.secondHalf());
    self.end = self.cursor;

    if (self.end.y > cursor_edit_pos.y) {
        try common.Ansi.cursor.prev_line(self.writer, self.end.y - cursor_edit_pos.y);
    }
    try common.Ansi.cursor.to(self.writer, cursor_edit_pos.x, null);

    self.cursor = cursor_edit_pos;
}

fn writeText(self: *PromptWriter, units: []const GapBuffer.Unit, utf8: []const u8) error{WriteFailed}!void {
    if (utf8.len == 0) {
        return;
    }

    var last: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        const remaining_space = self.winsize.x - self.cursor.x;

        const utf8_len = blk: {
            var utf8_len: usize = 0;
            var dw_len: u32 = 0;
            while (i < units.len) : (i += 1) {
                const unit = units[i];
                if (remaining_space < dw_len + unit.dw) {
                    break;
                }
                dw_len += unit.dw;
                utf8_len += unit.len;
            }

            self.cursor.x += dw_len;
            break :blk utf8_len;
        };

        const chunk = utf8[last .. last + utf8_len];
        last += utf8_len;

        try self.writer.writeAll(chunk);

        if (i < units.len) {
            try self.writer.writeByte('\n');
            self.cursor.x = 0;
            self.cursor.y += 1;
        }
    }
}

pub inline fn flush(self: *PromptWriter) error{WriteFailed}!void {
    return self.writer.flush();
}

pub fn updateWindowSize(self: *PromptWriter, new_size: Winsize) error{WriteFailed}!void {
    self.winsize = Vec2{ .x = new_size.cols, .y = new_size.rows };
    return self.redraw();
}

pub fn insertUGF8AtCursor(self: *PromptWriter, unit: *const UGF8.Unit) error{ OutOfMemory, WriteFailed }!void {
    try self.buf.insertUGF8AtCursor(self.allocator, unit);
    try self.redraw();
}

pub fn insertUGF8SliceAtCursor(self: *PromptWriter, slice: []const UGF8.Unit) error{ OutOfMemory, WriteFailed }!void {
    try self.buf.insertUGF8SliceAtCursor(self.allocator, slice);
    try self.redraw();
}

pub fn insertUGFAtCursor(self: *PromptWriter, unit: *const UGF.Unit) error{ OutOfMemory, WriteFailed, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
    try self.buf.insertUGFAtCursor(self.allocator, unit);
    try self.redraw();
}

pub fn insertUGFSliceAtCursor(self: *PromptWriter, slice: []const UGF.Unit) error{ OutOfMemory, WriteFailed, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
    try self.buf.insertUGFSliceAtCursor(self.allocator, slice);
    try self.redraw();
}

pub fn deleteBeforeCursor(self: *PromptWriter) error{WriteFailed}!void {
    if (self.buf.growGapLeft(1)) {
        try self.redraw();
    }
}

pub fn deleteAfterCursor(self: *PromptWriter) error{WriteFailed}!void {
    if (self.buf.growGapRight(1)) {
        try self.redraw();
    }
}

pub fn moveCursorRight(self: *PromptWriter, n: usize) error{WriteFailed}!void {
    if (@as(?[]const GapBuffer.Unit, self.buf.moveGapRight(n) catch null)) |moved_units| {
        var moved_len: u32 = 0;
        for (moved_units) |unit| {
            moved_len += unit.dw;
        }

        if (self.cursor.x + moved_len > self.winsize.x) {
            try self.redraw();
            return;
        }

        self.cursor.x += moved_len;
        try common.Ansi.cursor.forward(self.writer, moved_len);
    }
}

pub fn moveCursorLeft(self: *PromptWriter, n: usize) error{WriteFailed}!void {
    if (@as(?[]const GapBuffer.Unit, self.buf.moveGapLeft(n) catch null)) |moved_units| {
        if (self.cursor.x == 0 or (self.cursor.y == 0 and self.cursor.x == self.identation)) {
            try self.redraw();
            return;
        }

        var moved_len: u32 = 0;
        for (moved_units) |unit| {
            moved_len += unit.dw;
        }
        
        if (self.cursor.x - 1 < moved_len) {
            try self.redraw();
            return;
        }

        self.cursor.x -= moved_len;
        try common.Ansi.cursor.backward(self.writer, moved_len);
    }
}

pub fn moveCursorToEnd(self: *PromptWriter) error{WriteFailed}!void {
    if (self.end.y - self.cursor.y > 0) {
        try common.Ansi.cursor.next_line(self.writer, self.end.y - self.cursor.y);
    }
    try common.Ansi.cursor.to(self.writer, self.end.x, null);
}

pub fn toOwnedSlice(self: *const PromptWriter, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var buf_len: usize = 0;
    for (self.buf.firstHalf()) |g| {
        buf_len += g.data.len;
    }
    for (self.buf.secondHalf()) |g| {
        buf_len += g.data.len;
    }

    const first_half = self.buf.utf8.firstHalf();
    const second_half = self.buf.utf8.secondHalf();

    var buf = try allocator.alloc(u8, buf_len);
    @memcpy(buf[0..first_half.len], first_half);
    @memcpy(buf[first_half.len..], second_half);

    return buf;
}

pub const Vec2 = struct {
    x: u32,
    y: u32,
};
