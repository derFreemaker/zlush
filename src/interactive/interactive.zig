const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const zttio = @import("zttio");

const Zlush = @import("zlush");

const Prompt = @import("input/prompt.zig");

const Interactive = @This();

allocator: std.mem.Allocator,

tty: *zttio.Tty,

zlush: Zlush,

sw: *common.Stopwatch,

pub fn init(allocator: std.mem.Allocator, sw: *common.Stopwatch) error{ OutOfMemory, WriteFailed, NoTty, UnableToEnterRawMode, UnableToQueryTerminalCapabilities, UnableToGetWinsize, UnableToStartReader }!Interactive {
    try sw.begin("initialize interactive");
    defer sw.end();

    const tty = blk: {
        try sw.begin("start tty");
        defer sw.end();

        const tty = try zttio.Tty.init(allocator, allocator, .stdin(), .stdout(), null, .{});
        @import("root").global_tty = tty;
        break :blk tty;
    };

    return Interactive{
        .allocator = allocator,

        .tty = tty,

        .zlush = try .init(allocator, sw),

        .sw = sw,
    };
}

pub fn deinit(self: *Interactive) void {
    self.tty.deinit();
}

pub fn loop(self: *Interactive) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!u8 {
    try self.sw.display(self.tty.stdout);
    try self.tty.stdout.print("{any}\n", .{ self.tty.caps });
    while (true) {
        const stdout = self.tty.stdout;
        defer stdout.flush() catch @panic("unable to flush");

        var buf = self.promptUser(self.allocator) catch |err| switch (err) {
            error.EndOfInput => return 0,
            else => |e| return e,
        };
        defer buf.deinit(self.allocator);
        // defer self.allocator.free(buf);

        const raw_buf = buf.asUTF8Slice();
        
        if (std.mem.eql(u8, raw_buf, "exit")) {
            return 0;
        }

        if (std.mem.eql(u8, raw_buf, "clear")) {
            try stdout.writeAll("\x1b[2J\x1b[3J\x1b[H");
            continue;
        }

        try stdout.writeAll(raw_buf);
        try stdout.writeByte('\n');
        // const exit_code = try self.zlush.execute(buf);
        // try stdout.print("exitcode: {}\n", .{exit_code});
        try stdout.flush();
    }
    
    // var tui = try Tui.init(self.allocator);
    // tui.render(self.tty.stdoutWriter()) catch unreachable;
    
    return 0;
}

pub fn promptUser(self: *Interactive, allocator: std.mem.Allocator) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!common.Unicode.UGF8.Buffer {
    while (true) {
        const prompt_len = 7;
        const stdout = self.tty.stdout;
        try stdout.writeAll("zlush> ");
        try stdout.flush();

        var prompt = try Prompt.init(self.allocator, self.tty, prompt_len);
        defer prompt.deinit();

        const buf = prompt.readCommand(allocator) catch |err| switch (err) {
            error.CommandCanceled => {
                try stdout.print("{f}^C{s}\n", .{
                    common.AnsiColor.Coloring{
                        .foreground = .normal(.bright_red),
                    },
                    comptime common.AnsiColor.reset(),
                });
                try stdout.flush();
                continue;
            },
            error.CommandCanceledAndClear => {
                try stdout.writeAll("\x1b[2J\x1b[3J\x1b[H");
                try stdout.flush();
                continue;
            },
            else => |e| return e,
        };

        return buf;
    }
}
