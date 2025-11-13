const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const windows = std.os.windows;

pub const Signal = enum {
    INTERRUPT,
};

var sig_mutex: std.Thread.Mutex = .{};
var sigs: std.EnumSet(Signal) = .initEmpty();

fn handleSignal(sig: c_int) callconv(.c) void {
    if (sig == posix.SIG.INT) {
        sig_mutex.lock();
        defer sig_mutex.unlock();

        sigs.insert(.INTERRUPT);
    }
}

fn handleConsoleCtrl(dwCtrlType: std.os.windows.DWORD) callconv(.c) std.os.windows.BOOL {
    switch (dwCtrlType) {
        std.os.windows.CTRL_C_EVENT, std.os.windows.CTRL_BREAK_EVENT => {
            sig_mutex.lock();
            defer sig_mutex.unlock();

            sigs.insert(.INTERRUPT);
        },
        else => {
            return std.os.windows.FALSE;
        },
    }

    return std.os.windows.TRUE;
}

pub fn initSigHandler() error{FailedToSetHandler}!void {
    if (builtin.os.tag == .windows) {
        if (windows.kernel32.SetConsoleCtrlHandler(handleConsoleCtrl, 1) == 0) {
            return error.FailedToSetHandler;
        }
    } else {
        var act = posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = [_]c_ulong{ 0 },
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &act, null);
    }
}

pub fn reset(sig: Signal) void {
    sig_mutex.lock();
    defer sig_mutex.unlock();

    sigs.remove(sig);
}

pub fn recieved(sig: Signal) bool {
    sig_mutex.lock();
    defer sig_mutex.unlock();

    return sigs.contains(sig);
}
