const std = @import("std");
const windows = std.os.windows;
const common = @import("common");

const c = @import("win_console_c.zig");

const ReadToken = @import("input_reader.zig").ReadToken;

const WinConsoleReader = @This();

events: [32]c.InputRecord = undefined,
events_count: usize = 0,
events_pos: usize = 0,

pub fn init() WinConsoleReader {
    return WinConsoleReader{};
}

pub fn deinit(self: *WinConsoleReader) void {
    _ = self;
}

pub fn nextToken(self: *WinConsoleReader) error{ReadFailed}!?ReadToken {
    while (true) {
        const event = try self.peekEvent();
        if (event == null) {
            return null;
        }

        switch (event.?) {
            .key => |key_event| {
                self.tossEvent();

                if (key_event.uChar.UnicodeChar < 256) {
                    // see: https://www.ascii-code.com/
                    switch (key_event.uChar.AsciiChar) {
                        3 => return ReadToken{ .event = .interrupt },
                        4 => return ReadToken{ .event = .EOF },
                        7 => return ReadToken{ .event = .bell },
                        8 => return ReadToken{ .event = .backspace },
                        9 => return ReadToken{ .event = .tab },
                        11 => return ReadToken{ .event = .vertical_tab },
                        12 => return ReadToken{ .event = .form_feed },

                        32...126 => return ReadToken{ .event = .{ .grapheme = .{ .single = .{
                            .buf = .{ key_event.uChar.AsciiChar, 0, 0, 0 },
                            .len = 1,
                            .dw = 1,
                        } } } },

                        127 => return ReadToken{ .event = .delete },

                        // expanded ASCI table
                        160...255 => {
                            var buf: [4]u8 = undefined;
                            const len: u3 = @intCast(std.unicode.utf16LeToUtf8(&buf, &.{key_event.uChar.UnicodeChar}) catch unreachable);
                            return ReadToken{ .event = .{ .grapheme = .{ .single = .{
                                .buf = buf,
                                .len = len,
                                .dw = 1,
                            } } } };
                        },

                        else => {},
                    }
                }

                // see: https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
                switch (key_event.wVirtualKeyCode) {
                    0x30...0x39, 0x41...0x5a => continue, // ignore input event

                    0x0D => return ReadToken{ .event = .enter },
                    0x25 => return ReadToken{ .event = .left },
                    0x26 => return ReadToken{ .event = .up },
                    0x27 => return ReadToken{ .event = .right },
                    0x28 => return ReadToken{ .event = .down },
                    0x2e => return ReadToken{ .event = .delete },

                    0x00 => {
                        const cp = try self.getCodepoint(key_event);
                        return ReadToken{ .cp = cp };
                    },

                    else => {
                        // const log = std.log.scoped(.zlush);
                        // log.warn("unknown wVirtualKeyCode: 0x{x} - {any}", .{ key_event.wVirtualKeyCode, key_event });
                        continue;
                    },
                }
            },

            .focus => {
                self.tossEvent(); // ignore
            },

            else => {
                self.tossEvent();

                const log = std.log.scoped(.zlush);
                log.warn("unsupported windows input event: {s}\n", .{@tagName(event.?)});

                continue;
            },
        }
    }
}

fn getCodepoint(self: *WinConsoleReader, event: c.KEY_EVENT_RECORD) error{ReadFailed}!u21 {
    if (std.unicode.utf16IsHighSurrogate(event.uChar.UnicodeChar)) {
        // we assume there is another key event completing this one
        const completing_event = try self.peekEvent();
        if (completing_event == null) {
            return error.ReadFailed;
        }

        const next_key_event = completing_event.?.key;
        self.tossEvent();

        const cp = std.unicode.utf16DecodeSurrogatePair(&.{ event.uChar.UnicodeChar, next_key_event.uChar.UnicodeChar }) catch unreachable;
        return cp;
    }

    return event.uChar.UnicodeChar;
}

fn peekEvent(self: *WinConsoleReader) error{ReadFailed}!?c.InputRecord {
    if (self.events_pos >= self.events_count) {
        self.readNextEvents() catch |err| switch (err) {
            error.Unexpected => return error.ReadFailed,
        };
        if (self.events_count == 0) {
            return null;
        }
    }

    const event = self.events[self.events_pos];
    return event;
}

inline fn tossEvent(self: *WinConsoleReader) void {
    if (self.events_pos >= self.events_count) return;
    self.events_pos += 1;
}

inline fn remainingEvents(self: *const WinConsoleReader) usize {
    return self.events_count - self.events_pos;
}

fn readNextEvents(self: *WinConsoleReader) error{Unexpected}!void {
    self.events_count = 0;
    self.events_pos = 0;

    const stdin_handle = std.fs.File.stdin().handle;

    var numEvents: u32 = 0;
    if (c.GetNumberOfConsoleInputEvents(stdin_handle, &numEvents) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    if (numEvents == 0) {
        return;
    }
    const events_to_read = @min(numEvents, 32);

    var buf: [32]c.INPUT_RECORD = undefined;
    if (c.ReadConsoleInputW(stdin_handle, &buf, events_to_read, &numEvents) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    var i: usize = 0;
    for (buf[0..numEvents]) |event| {
        const transform = c.InputRecord.from(event);

        // we filter out any release keys since there is no use for them
        if (transform == .key and transform.key.bKeyDown == 0) {
            continue;
        }

        self.events[i] = transform;
        i += 1;
    }

    self.events_count = i;
}
