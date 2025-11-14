const std = @import("std");
const builtin = @import("builtin");

const win_c = @import("win_console_c.zig");

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
    const input_raw_mode: win_c.CONSOLE_MODE_INPUT = .{
        .WINDOW_INPUT = 0, // resize events
        .MOUSE_INPUT = 0,
        .EXTENDED_FLAGS = 0, // allow mouse events
        .PROCESSED_INPUT = 0,
        .LINE_INPUT = 0,
        .ECHO_INPUT = 0,
    };

    const output_raw_mode: win_c.CONSOLE_MODE_OUTPUT = .{
        .PROCESSED_OUTPUT = 1,
        .VIRTUAL_TERMINAL_PROCESSING = 1,
        // .ENABLE_LVB_GRID_WORLDWIDE = 1,
    };

    const windows = std.os.windows;
    const stdin: std.fs.File = .stdin();
    const stdout: std.fs.File = .stdout();

    const org_codepage = windows.kernel32.GetConsoleOutputCP();
    const org_input_mode = try win_c.getConsoleMode(win_c.CONSOLE_MODE_INPUT, stdin.handle);
    const org_output_mode = try win_c.getConsoleMode(win_c.CONSOLE_MODE_OUTPUT, stdout.handle);

    original_state = .{
        .codepage = org_codepage,
        .input_mode = org_input_mode,
        .output_mode = org_output_mode,
    };

    try win_c.setConsoleMode(stdin.handle, input_raw_mode);
    try win_c.setConsoleMode(stdout.handle, output_raw_mode);
    if (windows.kernel32.SetConsoleOutputCP(utf8_codepage) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
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
    const windows = std.os.windows;
    const stdin: std.fs.File = .stdin();
    const stdout: std.fs.File = .stdout();

    _ = windows.kernel32.SetConsoleOutputCP(state.codepage);
    win_c.setConsoleMode(stdin.handle, state.input_mode) catch {};
    win_c.setConsoleMode(stdout.handle, state.output_mode) catch {};
}

// fn disablePosix(state: PosixState) void {
//     std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, state.termios) catch {};
// }

const utf8_codepage: c_uint = 65001;

const WindowsState = struct {
    codepage: c_uint,
    input_mode: win_c.CONSOLE_MODE_INPUT,
    output_mode: win_c.CONSOLE_MODE_OUTPUT,
};

// const PosixState = struct {
//     termios: std.posix.termios,
// };
