const std = @import("std");
const windows = std.os.windows;

// From https://gitub.com/ziglibs/zig-windows-console and https://github.com/rockorager/libvaxis.
// Thanks :)

// Mouse buttons
// https://docs.microsoft.com/en-us/windows/console/mouse-event-record-str
pub const left_mouse_button = 0x0001;
pub const middle_mouse_button = 0x0004;
pub const right_mouse_button = 0x0002;

// ControlKeys
// https://docs.microsoft.com/en-us/windows/console/key-event-record-str
// [...$0.parentElement.children].map(_ => "pub const " + _.children[0].innerText.split(" ").map(_ => _.toLowerCase()).join(" = ")).join(";\n")+";\n"
pub const capslock_on = 0x0080;
pub const enhanced_key = 0x0100;
pub const left_alt_pressed = 0x0002;
pub const left_ctrl_pressed = 0x0008;
pub const numlock_on = 0x0020;
pub const right_alt_pressed = 0x0001;
pub const right_ctrl_pressed = 0x0004;
pub const scrolllock_on = 0x0040;
pub const shift_pressed = 0x0010;

// Mouse event flags
// https://docs.microsoft.com/en-us/windows/console/mouse-event-record-str
pub const double_click = 0x0002;
pub const mouse_hwheeled = 0x0008;
pub const mouse_moved = 0x0001;
pub const mouse_wheeled = 0x0004;

// Events
const union_unnamed_248 = extern union {
    UnicodeChar: windows.WCHAR,
    AsciiChar: windows.CHAR,
};
pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    uChar: union_unnamed_248,
    dwControlKeyState: windows.DWORD,
};
pub const PKEY_EVENT_RECORD = *KEY_EVENT_RECORD;

pub const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: windows.COORD,
    dwButtonState: windows.DWORD,
    dwControlKeyState: windows.DWORD,
    dwEventFlags: windows.DWORD,
};
pub const PMOUSE_EVENT_RECORD = *MOUSE_EVENT_RECORD;

pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: windows.COORD,
};
pub const PWINDOW_BUFFER_SIZE_RECORD = *WINDOW_BUFFER_SIZE_RECORD;

pub const MENU_EVENT_RECORD = extern struct {
    dwCommandId: windows.UINT,
};
pub const PMENU_EVENT_RECORD = *MENU_EVENT_RECORD;

pub const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: windows.BOOL,
};
pub const PFOCUS_EVENT_RECORD = *FOCUS_EVENT_RECORD;

const union_unnamed_249 = extern union {
    KeyEvent: KEY_EVENT_RECORD,
    MouseEvent: MOUSE_EVENT_RECORD,
    WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
    MenuEvent: MENU_EVENT_RECORD,
    FocusEvent: FOCUS_EVENT_RECORD,
};
pub const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    Event: union_unnamed_249,
};
pub const PINPUT_RECORD = [*]INPUT_RECORD;

pub const InputRecordType = enum(windows.WORD) {
    key = 0x0001,
    mouse = 0x0002,
    windowSize = 0x0004,
    menu = 0x0008,
    focus = 0x0010,
};

pub const InputRecord = union(InputRecordType) {
    key: KEY_EVENT_RECORD,
    mouse: MOUSE_EVENT_RECORD,
    windowSize: WINDOW_BUFFER_SIZE_RECORD,
    /// used internally and should be ignored
    menu: MENU_EVENT_RECORD,
    focus: FOCUS_EVENT_RECORD,

    pub fn from(record: INPUT_RECORD) InputRecord {
        switch (@as(InputRecordType, @enumFromInt(record.EventType))) {
            InputRecordType.key => {
                return .{ .key = record.Event.KeyEvent };
            },
            InputRecordType.mouse => {
                return .{ .mouse = record.Event.MouseEvent };
            },
            InputRecordType.windowSize => {
                return .{ .windowSize = record.Event.WindowBufferSizeEvent };
            },
            InputRecordType.menu => {
                return .{ .menu = record.Event.MenuEvent };
            },
            InputRecordType.focus => {
                return .{ .focus = record.Event.FocusEvent };
            },
        }
    }
};

/// see: https://learn.microsoft.com/en-us/windows/console/getconsolemode
pub const CONSOLE_MODE_INPUT = packed struct(u32) {
    PROCESSED_INPUT: u1 = 0,
    LINE_INPUT: u1 = 0,
    ECHO_INPUT: u1 = 0,
    WINDOW_INPUT: u1 = 0,
    MOUSE_INPUT: u1 = 0,
    INSERT_MODE: u1 = 0,
    QUICK_EDIT_MODE: u1 = 0,
    EXTENDED_FLAGS: u1 = 0,
    AUTO_POSITION: u1 = 0,
    VIRTUAL_TERMINAL_INPUT: u1 = 0,
    _: u22 = 0,
};

/// see: https://learn.microsoft.com/en-us/windows/console/getconsolemode
pub const CONSOLE_MODE_OUTPUT = packed struct(u32) {
    PROCESSED_OUTPUT: u1 = 0,
    WRAP_AT_EOL_OUTPUT: u1 = 0,
    VIRTUAL_TERMINAL_PROCESSING: u1 = 0,
    DISABLE_NEWLINE_AUTO_RETURN: u1 = 0,
    ENABLE_LVB_GRID_WORLDWIDE: u1 = 0,
    _: u27 = 0,
};

pub fn getConsoleMode(comptime T: type, handle: windows.HANDLE) !T {
    var mode: u32 = undefined;
    if (windows.kernel32.GetConsoleMode(handle, &mode) == 0) return switch (windows.kernel32.GetLastError()) {
        .INVALID_HANDLE => error.InvalidHandle,
        else => |e| windows.unexpectedError(e),
    };
    return @bitCast(mode);
}

pub fn setConsoleMode(handle: windows.HANDLE, mode: anytype) !void {
    if (windows.kernel32.SetConsoleMode(handle, @bitCast(mode)) == 0) return switch (windows.kernel32.GetLastError()) {
        .INVALID_HANDLE => error.InvalidHandle,
        else => |e| windows.unexpectedError(e),
    };
}

pub extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: PINPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn PeekConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: PINPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: windows.HANDLE,
    lpcNumberOfEvents: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
