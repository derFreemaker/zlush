const std = @import("std");
const windows = std.os.windows;

const c = @import("win_console_c.zig");

const InputToken = @import("input_token.zig").InputToken;

const WinConsoleReader = @This();

allocator: std.mem.Allocator,

events: std.ArrayListUnmanaged(c.InputRecord),

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!WinConsoleReader {
    return WinConsoleReader{
        .allocator = allocator,

        .events = try .initCapacity(allocator, 32),
    };
}

pub fn deinit(self: *WinConsoleReader) void {
    self.events.deinit(self.allocator);
}

pub fn nextToken(self: *WinConsoleReader) error{ OutOfMemory, ReadFailed }!InputToken {
    while (true) {
        const event = self.peekEvent();
        if (event == null) {
            self.readNextEvents() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unexpected => return error.ReadFailed,
            };
            continue;
        }
        
        return switch (event.?) {
            .key => |key_event| {
                self.tossEvent();

                // see: https://www.ascii-code.com/
                switch (key_event.uChar.UnicodeChar) {
                    3 => return .interrupt,
                    4 => return .EOF,
                    6 => return .clearScreen,
                    7 => return .bell,
                    8 => return .backspace,
                    9 => return .tab,
                    11 => return .vertical_tab,
                    12 => return .form_feed,

                    32...126 => return InputToken{ .grapheme = .{ .single = .{
                        .buf = .{ key_event.uChar.AsciiChar, 0, 0, 0 },
                        .len = 1,
                        .dw = 1,
                    } } },

                    127 => return .delete,

                    160...255 => {
                        const buf: [4]u8, const len: u3 = utf16ToUtf8(key_event.uChar.UnicodeChar);
                        return InputToken{ .grapheme = .{ .single = .{
                            .buf = buf,
                            .len = len,
                            .dw = 1,
                        } } };
                    },

                    else => {},
                }

                // see: https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
                switch (key_event.wVirtualKeyCode) {
                    0x30...0x39, 0x41...0x5a => continue, // ignore input event

                    0x00 => {
                        if (std.unicode.utf16IsHighSurrogate(key_event.uChar.UnicodeChar)) {
                            // we assume there is another event completing this one
                            const next_event = self.peekEvent().?.key;
                            self.tossEvent();

                            const code_point = std.unicode.utf16DecodeSurrogatePair(&.{ key_event.uChar.UnicodeChar, next_event.uChar.UnicodeChar }) catch unreachable;

                            var token = InputToken{ .grapheme = .{ .single = undefined } };
                            token.grapheme.single.len = std.unicode.utf8Encode(code_point, &token.grapheme.single.buf) catch unreachable;
                            token.grapheme.single.dw = 2;

                            return token;
                        }

                        //TODO: implement cache/storage for graphemes
                        std.debug.panic("not implemented: {any}", .{key_event});
                    },

                    0x09 => return .tab,
                    0x0D => return .enter,
                    0x13 => return .pause,
                    0x14 => return .caps_lock,
                    0x1B => return .escape,
                    0x20 => return .space,
                    0x21 => return .page_up,
                    0x22 => return .page_down,
                    0x23 => return .end,
                    0x24 => return .home,
                    0x25 => return .left,
                    0x26 => return .up,
                    0x27 => return .right,
                    0x28 => return .down,
                    0x2c => return .print_screen,
                    0x2d => return .insert,
                    0x2e => return .delete,
                    0x5b => return .left_meta,
                    0x5c => return .right_meta,

                    0x60 => return .kp_0,
                    0x61 => return .kp_1,
                    0x62 => return .kp_2,
                    0x63 => return .kp_3,
                    0x64 => return .kp_4,
                    0x65 => return .kp_5,
                    0x66 => return .kp_6,
                    0x67 => return .kp_7,
                    0x68 => return .kp_8,
                    0x69 => return .kp_9,
                    0x6a => return .kp_multiply,
                    0x6b => return .kp_add,
                    0x6c => return .kp_separator,
                    0x6d => return .kp_subtract,
                    0x6e => return .kp_decimal,
                    0x6f => return .kp_divide,

                    0x70 => return .f1,
                    0x71 => return .f2,
                    0x72 => return .f3,
                    0x73 => return .f4,
                    0x74 => return .f5,
                    0x75 => return .f6,
                    0x76 => return .f7,
                    0x77 => return .f8,
                    0x78 => return .f9,
                    0x79 => return .f10,
                    0x7a => return .f11,
                    0x7b => return .f12,
                    0x7c => return .f13,
                    0x7d => return .f14,
                    0x7e => return .f15,
                    0x7f => return .f16,
                    0x80 => return .f17,
                    0x81 => return .f18,
                    0x82 => return .f19,
                    0x83 => return .f20,
                    0x84 => return .f21,
                    0x85 => return .f22,
                    0x86 => return .f23,
                    0x87 => return .f24,
                    0x90 => return .num_lock,
                    0x91 => return .scroll_lock,
                    0xa0 => return .left_shift,
                    0x10 => return .right_shift,
                    0xa1 => return .right_shift,
                    0xa2 => return .left_control,
                    0x11 => return .left_control,
                    0xa3 => return .right_control,
                    0xa4 => return .left_alt,
                    0x12 => return .left_alt,
                    0xa5 => return .right_alt,
                    0xad => return .mute_volume,
                    0xae => return .lower_volume,
                    0xaf => return .raise_volume,
                    0xb0 => return .media_track_next,
                    0xb1 => return .media_track_prev,
                    0xb2 => return .media_stop,
                    0xb3 => return .media_play_pause,

                    else => {
                        // std.debug.panic("unknown wVirtualKeyCode: 0x{x} unichar code: {any}", .{ key_event.wVirtualKeyCode, key_event });
                        continue;
                    },
                }
            },
            else => {
                self.tossEvent();
                // std.debug.print("got unsupported event: {s}\n", .{@tagName(event.?)});
                continue;
            },
        };
    }
}

fn utf16ToUtf8(code_unit: u16) std.meta.Tuple(&.{ [4]u8, u3 }) {
    var bytes: [4]u8 = [_]u8{0} ** 4;
    var len: u3 = 0;

    if (code_unit <= 0x7F) {
        // 1-byte sequence: 0xxxxxxx
        bytes[0] = @intCast(code_unit);
        len = 1;
    } else if (code_unit <= 0x7FF) {
        // 2-byte sequence: 110xxxxx 10xxxxxx
        bytes[0] = @intCast(0xC0 | (code_unit >> 6));
        bytes[1] = @intCast(0x80 | (code_unit & 0x3F));
        len = 2;
    } else {
        // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        bytes[0] = @intCast(0xE0 | (code_unit >> 12));
        bytes[1] = @intCast(0x80 | ((code_unit >> 6) & 0x3F));
        bytes[2] = @intCast(0x80 | (code_unit & 0x3F));
        len = 3;
    }

    return .{ bytes, len };
}

fn peekEvent(self: *WinConsoleReader) ?c.InputRecord {
    if (self.events.items.len == 0) {
        return null;
    }
    return self.events.items[0];
}

fn tossEvent(self: *WinConsoleReader) void {
    _ = self.events.orderedRemove(0);
}

fn readNextEvents(self: *WinConsoleReader) error{ OutOfMemory, Unexpected }!void {
    const stdin_handle = std.fs.File.stdin().handle;

    var numEvents: u32 = 0;
    if (c.GetNumberOfConsoleInputEvents(stdin_handle, &numEvents) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    if (numEvents == 0) {
        return;
    }

    var dummy: u32 = 0;
    const buf = try self.allocator.alloc(c.INPUT_RECORD, numEvents);
    defer self.allocator.free(buf);
    if (c.ReadConsoleInputW(stdin_handle, buf.ptr, numEvents, &dummy) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    try self.events.ensureUnusedCapacity(self.allocator, buf.len);
    for (buf) |event| {
        const transform = c.InputRecord.from(event);
        if (transform == .key and transform.key.bKeyDown == 0) {
            continue;
        }

        self.events.appendAssumeCapacity(transform);
    }
}
