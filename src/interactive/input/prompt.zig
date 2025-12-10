const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Event = @import("event.zig").Event;
const InputReader = @import("input_reader.zig");
const PromptWriter = @import("prompt_writer.zig");

const Prompt = @This();

reader: *InputReader,
writer: PromptWriter,

pub fn init(allocator: std.mem.Allocator, reader: *InputReader, writer: *std.Io.Writer, identation: u32) error{OutOfMemory}!Prompt {
    const winsize = reader.getWindowSize() catch @panic("unbale to get window size");
    const prompt_writer = PromptWriter.init(allocator, writer, identation, winsize);

    return Prompt{
        .reader = reader,
        .writer = prompt_writer,
    };
}

pub fn deinit(self: *Prompt) void {
    self.writer.deinit();
}

pub fn readCommand(self: *Prompt, allocator: std.mem.Allocator) error{ CommandCanceled, CommandCanceledAndClear, EndOfInput, OutOfMemory, EchoingStateFailed }!common.Unicode.UGF8.Buffer {
    while (true) {
        var event = self.reader.nextEvent();

        switch (event) {
            .grapheme => |*g| {
                defer g.deinit(self.reader.allocator);

                self.writer.insertAtCursor(g) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.WriteFailed => return error.EchoingStateFailed,
                    else => unreachable,
                };
            },
            .enter => {
                break;
            },

            .backspace => {
                self.writer.deleteBeforeCursor() catch return error.EchoingStateFailed;
            },

            .interrupt => {
                self.writer.moveCursorToEnd() catch return error.EchoingStateFailed;
                return error.CommandCanceled;
            },

            .EOF => {
                return error.EndOfInput;
            },

            .form_feed => {
                return error.CommandCanceledAndClear;
            },

            .right => {
                self.writer.moveCursorRight(1) catch return error.EchoingStateFailed;
            },
            .left => {
                self.writer.moveCursorLeft(1) catch return error.EchoingStateFailed;
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

    return self.writer.buf.toBuffer(allocator);
}
