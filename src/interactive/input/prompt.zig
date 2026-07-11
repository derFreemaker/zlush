const std = @import("std");
const builtin = @import("builtin");
const zttio = @import("zttio");
const common = @import("common");

const Tty = zttio.Tty;
const Event = zttio.Event;
const Key = zttio.Key;
const PromptWriter = @import("prompt_writer.zig");

const Prompt = @This();

tty: *Tty,
writer: PromptWriter,

pub fn init(allocator: std.mem.Allocator, tty: *Tty, identation: u32) error{OutOfMemory}!Prompt {
    const winsize = tty.updateWinsize() catch @panic("unbale to get window size");
    const prompt_writer = PromptWriter.init(allocator, tty.stdout, identation, winsize);

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
        defer event.deinit(self.tty.event_allocator);

        switch (event) {
            //     .paste => |p| {
            //         self.writer.insertCharAtCursor("ctl-v", 5) catch return error.EchoingStateFailed;
            //     },

            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.writer.moveCursorToEnd() catch return error.EchoingStateFailed;
                    return error.CommandCanceled;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    return error.CommandCanceledAndClear;
                } else if (key.matches('d', .{ .ctrl = true })) {
                    return error.EndOfInput;
                } else if (key.matches(Key.enter, .{})) {
                    break;
                } else if (key.matches(Key.backspace, .{})) {
                    self.writer.deleteBeforeCursor() catch return error.EchoingStateFailed;
                } else if (key.matches(Key.delete, .{})) {
                    self.writer.deleteAfterCursor() catch return error.EchoingStateFailed;
                } else if (key.matches(Key.right, .{})) {
                    self.writer.moveCursorRight(1) catch return error.EchoingStateFailed;
                } else if (key.matches(Key.left, .{})) {
                    self.writer.moveCursorLeft(1) catch return error.EchoingStateFailed;
                } else {
                    if (key.text) |text| {
                        self.writer.insertCharAtCursor(text, self.tty.strWidth(text)) catch return error.EchoingStateFailed;
                    }
                }
            },

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

    return try self.writer.buf.cloneToBuffer(allocator);
}
