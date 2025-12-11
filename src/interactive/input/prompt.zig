const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Tty = @import("../../tui/input/tty.zig");
const Event = @import("event.zig").Event;
const Key = @import("../../tui/input/key.zig");
const InputReader = @import("input_reader.zig");
const PromptWriter = @import("prompt_writer.zig");

const Prompt = @This();

tty: *Tty,
writer: PromptWriter,

pub fn init(allocator: std.mem.Allocator, tty: *Tty, identation: u32) error{OutOfMemory}!Prompt {
    const winsize = tty.getWindowSize() catch @panic("unbale to get window size");
    const prompt_writer = PromptWriter.init(allocator, tty.stdoutWriter(), identation, winsize);

    return Prompt{
        .tty = tty,
        .writer = prompt_writer,
    };
}

pub fn deinit(self: *Prompt) void {
    self.writer.deinit();
}

pub fn readCommand(self: *Prompt, allocator: std.mem.Allocator) error{ CommandCanceled, CommandCanceledAndClear, EndOfInput, OutOfMemory, EchoingStateFailed }!common.Unicode.UGF8.Buffer {
    while (true) {
        var event = self.tty.nextEvent();

        switch (event) {
            .paste => |*p| {
                defer p.deinit();

                self.writer.insertUGFSliceAtCursor(p.buf) catch return error.EchoingStateFailed;
            },

            .key_press => |p| {
                if (p.matchShortcut('c', .{ .ctrl = true })) {
                    self.writer.moveCursorToEnd() catch return error.EchoingStateFailed;
                    return error.CommandCanceled;
                } else if (p.matchShortcut('l', .{ .ctrl = true })) {
                    return error.CommandCanceledAndClear;
                } else if (p.matchShortcut('d', .{ .ctrl = true })) {
                    return error.EndOfInput;
                } else if (p.matchShortcut(Key.enter, .{})) {
                    break;
                } else if (p.matchShortcut(Key.backspace, .{})) {
                    self.writer.deleteBeforeCursor() catch return error.EchoingStateFailed;
                } else if (p.matchShortcut(Key.delete, .{})) {
                    self.writer.deleteAfterCursor() catch return error.EchoingStateFailed;
                } else if (p.matchShortcut(Key.right, .{})) {
                    self.writer.moveCursorRight(1) catch return error.EchoingStateFailed;
                } else if (p.matchShortcut(Key.left, .{})) {
                    self.writer.moveCursorLeft(1) catch return error.EchoingStateFailed;
                } else {
                    if (p.is_char) {
                        self.writer.insertUGFAtCursor(&p.asUGF()) catch return error.EchoingStateFailed;
                    }
                }
            },

            // .grapheme => |*g| {
            //     defer g.deinit(self.reader.allocator);
            //
            //     self.writer.insertAtCursor(g) catch |err| switch (err) {
            //         error.OutOfMemory => |e| return e,
            //         error.WriteFailed => return error.EchoingStateFailed,
            //         else => unreachable,
            //     };
            // },
            // .enter => {
            //     break;
            // },

            // .backspace => {
            //     self.writer.deleteBeforeCursor() catch return error.EchoingStateFailed;
            // },
            //
            // .interrupt => {
            //     self.writer.moveCursorToEnd() catch return error.EchoingStateFailed;
            //     return error.CommandCanceled;
            // },
            //
            // .EOF => {
            //     return error.EndOfInput;
            // },
            //
            // .form_feed => {
            //     return error.CommandCanceledAndClear;
            // },
            //
            // .right => {
            //     self.writer.moveCursorRight(1) catch return error.EchoingStateFailed;
            // },
            // .left => {
            //     self.writer.moveCursorLeft(1) catch return error.EchoingStateFailed;
            // },

            .winsize => |w| {
                self.writer.updateWindowSize(w) catch return error.EchoingStateFailed;
            },

            else => {
                // std.debug.print("prompt: event ignored: {any}\n", .{event});
            },
        }

        self.writer.flush() catch return error.EchoingStateFailed;
    }

    self.writer.writer.writeByte('\n') catch return error.EchoingStateFailed;
    self.writer.flush() catch return error.EchoingStateFailed;

    return self.writer.buf.toBuffer(allocator);
}
