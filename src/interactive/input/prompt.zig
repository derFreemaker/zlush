const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Grapheme = @import("input_token.zig").InputToken.Grapheme;
const ConsoleReader =
    if (builtin.os.tag == .windows)
        @import("win_console_reader.zig")
    else
        @compileError("not implemented");

const Prompt = @This();

allocator: std.mem.Allocator,

reader: ConsoleReader,
writer: *std.Io.Writer,

cursor_dpos: usize,
graphemes: common.GapBuffer(Grapheme, .{}),

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Prompt {
    return Prompt{
        .allocator = allocator,

        .reader = .init(allocator),
        .writer = writer,

        .cursor_dpos = 0,
        .graphemes = .init,
    };
}

pub fn deinit(self: *Prompt) void {
    self.graphemes.clearAndFree(self.allocator);
}

pub fn redraw(self: *Prompt) error{EchoingStateFailed}!void {
    var dw_first: usize = 0;
    for (self.graphemes.firstHalf()) |g| {
        dw_first += g.dw();
    }
    var dw_second: usize = 0;
    for (self.graphemes.secondHalf()) |g| {
        dw_second += g.dw();
    }

    if (self.cursor_dpos > 0) {
        self.writer.print("\x1b[{}D", .{self.cursor_dpos}) catch return error.EchoingStateFailed;
    }
    self.writer.writeAll("\x1b[0K") catch return error.EchoingStateFailed;

    for (self.graphemes.firstHalf()) |g| {
        self.writer.writeAll(g.get()) catch return error.EchoingStateFailed;
    }
    for (self.graphemes.secondHalf()) |g| {
        self.writer.writeAll(g.get()) catch return error.EchoingStateFailed;
    }

    if (dw_second > 0) {
        self.writer.print("\x1b[{}D", .{dw_second}) catch return error.EchoingStateFailed;
    }

    self.writer.flush() catch return error.EchoingStateFailed;
    
    self.cursor_dpos = dw_first;
}

pub fn readCommand(self: *Prompt, allocator: std.mem.Allocator) error{ CommandCanceled, CommandCanceledAndClear, EndOfInput, OutOfMemory, ReadingCommandFailed, EchoingStateFailed }![]const u8 {
    while (true) {
        const token = self.reader.nextToken() catch |err| switch (err) {
            error.ReadFailed => return error.ReadingCommandFailed,
            // error.EndOfStream => return error.EndOfStream,
        };

        switch (token) {
            .grapheme => |g| {
                try self.graphemes.insertAtCursor(self.allocator, g);

                try self.redraw();
            },
            .space => {
                const space_grapheme = comptime Grapheme{ .single = Grapheme.Single{
                    .buf = .{ ' ', 0, 0, 0 },
                    .len = 1,
                    .dw = 1,
                } };
                try self.graphemes.insertAtCursor(self.allocator, space_grapheme);

                try self.redraw();
            },
            .enter => {
                self.writer.writeByte('\n') catch return error.EchoingStateFailed;
                self.writer.flush() catch return error.EchoingStateFailed;
                break;
            },

            .backspace => {
                if (self.graphemes.growGapLeft(1)) {
                    try self.redraw();
                }
            },

            .interrupt => {
                return error.CommandCanceled;
            },

            .EOF => {
                return error.EndOfInput;
            },

            .clearScreen => {
                return error.CommandCanceledAndClear;
            },

            .right => {
                if (self.graphemes.moveGapRight(1)) {
                    const first_half = self.graphemes.firstHalf();
                    const dw = first_half[first_half.len - 1].dw();
                    self.cursor_dpos += dw;

                    self.writer.print("\x1b[{}C", .{dw}) catch return error.EchoingStateFailed;
                    self.writer.flush() catch return error.EchoingStateFailed;
                }
            },
            .left => {
                if (self.graphemes.moveGapLeft(1)) {
                    const dw = self.graphemes.secondHalf()[0].dw();
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
    for (self.graphemes.firstHalf()) |g| {
        buf_len += g.lenBytes();
    }
    for (self.graphemes.secondHalf()) |g| {
        buf_len += g.lenBytes();
    }

    var buf_writer: std.Io.Writer.Allocating = try .initCapacity(allocator, buf_len);
    defer buf_writer.deinit();

    for (self.graphemes.firstHalf()) |g| {
        buf_writer.writer.writeAll(g.get()) catch unreachable;
    }
    for (self.graphemes.secondHalf()) |g| {
        buf_writer.writer.writeAll(g.get()) catch unreachable;
    }

    return buf_writer.toOwnedSlice();
}
