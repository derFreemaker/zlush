const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Grapheme = @import("event.zig").Grapheme;
const InputReader = @import("input_reader.zig");

const Prompt = @This();

allocator: std.mem.Allocator,

reader: *InputReader,
writer: *std.Io.Writer,

buf: common.GapBuffer(Grapheme, .{}),
cursor_dpos: usize,

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) error{OutOfMemory}!Prompt {
    const reader = try InputReader.init(allocator);
    reader.start() catch @panic("unable to start console reader thread");
    
    return Prompt{
        .allocator = allocator,

        .reader = reader,
        .writer = writer,

        .buf = .init,
        .cursor_dpos = 0,
    };
}

pub fn deinit(self: *Prompt) void {
    self.reader.deinit();

    self.buf.clearAndFree(self.allocator);
}

pub fn redraw(self: *Prompt) error{EchoingStateFailed}!void {
    var dw_first: usize = 0;
    for (self.buf.firstHalf()) |g| {
        dw_first += g.dw();
    }
    var dw_second: usize = 0;
    for (self.buf.secondHalf()) |g| {
        dw_second += g.dw();
    }

    if (self.cursor_dpos > 0) {
        self.writer.print("\x1b[{}D", .{self.cursor_dpos}) catch return error.EchoingStateFailed;
    }
    self.writer.writeAll("\x1b[0K") catch return error.EchoingStateFailed;

    for (self.buf.firstHalf()) |g| {
        self.writer.writeAll(g.get()) catch return error.EchoingStateFailed;
    }
    for (self.buf.secondHalf()) |g| {
        self.writer.writeAll(g.get()) catch return error.EchoingStateFailed;
    }

    if (dw_second > 0) {
        self.writer.print("\x1b[{}D", .{dw_second}) catch return error.EchoingStateFailed;
    }

    self.writer.flush() catch return error.EchoingStateFailed;

    self.cursor_dpos = dw_first;
}

pub fn readCommand(self: *Prompt, allocator: std.mem.Allocator) error{ CommandCanceled, CommandCanceledAndClear, EndOfInput, OutOfMemory, EchoingStateFailed }![]const u8 {
    while (true) {
        const event = self.reader.nextEvent();

        switch (event) {
            .grapheme => |g| {
                try self.buf.insertAtCursor(self.allocator, g);

                try self.redraw();
            },
            .enter => {
                self.writer.writeByte('\n') catch return error.EchoingStateFailed;
                self.writer.flush() catch return error.EchoingStateFailed;
                break;
            },

            .backspace => {
                if (self.buf.growGapLeft(1)) {
                    try self.redraw();
                }
            },

            .interrupt => {
                return error.CommandCanceled;
            },

            .EOF => {
                return error.EndOfInput;
            },

            .form_feed => {
                return error.CommandCanceledAndClear;
            },

            .right => {
                if (self.buf.moveGapRight(1)) {
                    const first_half = self.buf.firstHalf();
                    const dw = first_half[first_half.len - 1].dw();
                    self.cursor_dpos += dw;

                    self.writer.print("\x1b[{}C", .{dw}) catch return error.EchoingStateFailed;
                    self.writer.flush() catch return error.EchoingStateFailed;
                }
            },
            .left => {
                if (self.buf.moveGapLeft(1)) {
                    const dw = self.buf.secondHalf()[0].dw();
                    self.cursor_dpos -= dw;

                    self.writer.print("\x1b[{}D", .{dw}) catch return error.EchoingStateFailed;
                    self.writer.flush() catch return error.EchoingStateFailed;
                }
            },

            else => {
                // std.debug.print("token ignored\n", .{});
            },
        }
    }

    var buf_len: usize = 0;
    for (self.buf.firstHalf()) |g| {
        buf_len += g.lenBytes();
    }
    for (self.buf.secondHalf()) |g| {
        buf_len += g.lenBytes();
    }

    var buf_writer: std.Io.Writer.Allocating = try .initCapacity(allocator, buf_len);
    defer buf_writer.deinit();

    for (self.buf.firstHalf()) |g| {
        buf_writer.writer.writeAll(g.get()) catch unreachable;
    }
    for (self.buf.secondHalf()) |g| {
        buf_writer.writer.writeAll(g.get()) catch unreachable;
    }

    return buf_writer.toOwnedSlice();
}
