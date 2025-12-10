const std = @import("std");
const builtin = @import("builtin");

const zigwin = @import("zigwin");
const winconsole = zigwin.system.console;
const windows = std.os.windows;

var original_state: ?if (builtin.os.tag == .windows)
    WindowsState
else
    // PosixState = null;
    @compileError("not implemented") = null;

pub fn enable() !void {
    if (builtin.os.tag == .windows) {
        try enableWindows();
    } else {
        @compileError("not implemented");
        // try enablePosix();
    }
}

fn enableWindows() !void {
    const input_raw_mode: WIN_CONSOLE_MODE_INPUT = .{
        .WINDOW_INPUT = 1, // resize events
        .MOUSE_INPUT = 0,
        .EXTENDED_FLAGS = 0, // allow mouse events
        .PROCESSED_INPUT = 0,
        .LINE_INPUT = 0,
        .ECHO_INPUT = 0,
    };

    const output_raw_mode: WIN_CONSOLE_MODE_OUTPUT = .{
        .PROCESSED_OUTPUT = 1,
        .VIRTUAL_TERMINAL_PROCESSING = 1,
        // .ENABLE_LVB_GRID_WORLDWIDE = 1,
    };

    const stdin: std.fs.File = .stdin();
    const stdout: std.fs.File = .stdout();

    const org_codepage = winconsole.GetConsoleOutputCP();
    const org_input_mode = try getConsoleMode(WIN_CONSOLE_MODE_INPUT, stdin.handle);
    const org_output_mode = try getConsoleMode(WIN_CONSOLE_MODE_OUTPUT, stdout.handle);

    original_state = .{
        .codepage = org_codepage,
        .input_mode = org_input_mode,
        .output_mode = org_output_mode,
    };

    try setConsoleMode(stdin.handle, input_raw_mode);
    try setConsoleMode(stdout.handle, output_raw_mode);
    if (winconsole.SetConsoleOutputCP(utf8_codepage) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
}

pub fn disable() void {
    if (original_state == null) {
        return;
    }
    const state = original_state.?;

    if (builtin.os.tag == .windows) {
        disableWindows(state);
    } else {
        @compileError("not implemented");
        // disablePosix(state);
    }

    original_state = null;
}

fn disableWindows(state: WindowsState) void {
    const stdin: std.fs.File = .stdin();
    const stdout: std.fs.File = .stdout();

    _ = winconsole.SetConsoleOutputCP(state.codepage);
    setConsoleMode(stdin.handle, state.input_mode) catch {};
    setConsoleMode(stdout.handle, state.output_mode) catch {};
}

/// see: https://learn.microsoft.com/en-us/windows/console/getconsolemode
pub const WIN_CONSOLE_MODE_INPUT = packed struct(u32) {
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
pub const WIN_CONSOLE_MODE_OUTPUT = packed struct(u32) {
    PROCESSED_OUTPUT: u1 = 0,
    WRAP_AT_EOL_OUTPUT: u1 = 0,
    VIRTUAL_TERMINAL_PROCESSING: u1 = 0,
    DISABLE_NEWLINE_AUTO_RETURN: u1 = 0,
    ENABLE_LVB_GRID_WORLDWIDE: u1 = 0,
    _: u27 = 0,
};

pub fn getConsoleMode(comptime T: type, handle: std.os.windows.HANDLE) !T {
    var mode: u32 = undefined;
    if (winconsole.GetConsoleMode(handle, @ptrCast(&mode)) == 0) return switch (windows.kernel32.GetLastError()) {
        .INVALID_HANDLE => error.InvalidHandle,
        else => |e| windows.unexpectedError(e),
    };
    return @bitCast(mode);
}

pub fn setConsoleMode(handle: std.os.windows.HANDLE, mode: anytype) !void {
    if (winconsole.SetConsoleMode(handle, @bitCast(mode)) == 0) return switch (windows.kernel32.GetLastError()) {
        .INVALID_HANDLE => error.InvalidHandle,
        else => |e| windows.unexpectedError(e),
    };
}

// fn enablePosix() !void {
//     const stdin_fd = std.posix.STDIN_FILENO;
//     const original = try std.posix.tcgetattr(stdin_fd);
//
//     var raw = original;
//     raw.lflag.ECHO = false;
//     raw.lflag.ICANON = false;
//     raw.lflag.ISIG = false;
//     raw.lflag.IEXTEN = false;
//     raw.iflag.IXON = false;
//     raw.iflag.ICRNL = false;
//     raw.iflag.BRKINT = false;
//     raw.iflag.INPCK = false;
//     raw.iflag.ISTRIP = false;
//     raw.oflag.OPOST = false;
//     raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
//     raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
//
//     try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
//
//     original_state = .{ .termios = original };
// }

// fn disablePosix(state: PosixState) void {
//     std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, state.termios) catch {};
// }

const utf8_codepage: c_uint = 65001;

const WindowsState = struct {
    codepage: c_uint,
    input_mode: WIN_CONSOLE_MODE_INPUT,
    output_mode: WIN_CONSOLE_MODE_OUTPUT,
};

// const PosixState = struct {
//     termios: std.posix.termios,
// };
