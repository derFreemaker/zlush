const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Zlush = @import("zlush");

const RawMode = @import("raw_mode.zig");

const Tty = @import("../tui/input/tty.zig");
const InputReader = @import("input/input_reader.zig");
const Prompt = @import("input/prompt.zig");

const Interactive = @This();

allocator: std.mem.Allocator,

// reader: *InputReader,
tty: *Tty,

zlush: Zlush,

sw: *common.Stopwatch,

pub fn init(allocator: std.mem.Allocator, sw: *common.Stopwatch) error{ FailedToSetRawMode, OutOfMemory }!Interactive {
    try sw.begin("initialize interactive");
    defer sw.end();

    // RawMode.enable() catch return error.FailedToSetRawMode;
    //
    // const reader = blk: {
    //     try sw.begin("start input reader");
    //     defer sw.end();
    //
    //     const reader = try InputReader.init(allocator);
    //     reader.start() catch @panic("unable to start console reader thread");
    //     break :blk reader;
    // };

    const tty = blk: {
        try sw.begin("start tty");
        defer sw.end();

        const tty = try Tty.init(allocator, allocator, std.fs.File.stdin(), std.fs.File.stdout(), std.fs.File.stderr());
        tty.start() catch @panic("unable to start tty");
        break :blk tty;
    };

    return Interactive{
        .allocator = allocator,

        // .reader = reader,
        .tty = tty,

        .zlush = try .init(allocator, sw),

        .sw = sw,
    };
}

pub fn deinit(self: *Interactive) void {
    self.tty.deinit();
    
    RawMode.disable();
}

pub fn loop(self: *Interactive) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!u8 {
    try self.sw.display(self.tty.stdoutWriter());
    while (true) {
        const stdout = self.tty.stdoutWriter();
        defer stdout.flush() catch @panic("unable to flush");

        var buf = self.promptUser(self.allocator) catch |err| switch (err) {
            error.EndOfInput => return 0,
            else => |e| return e,
        };
        defer buf.deinit(self.allocator);
        const raw_buf = buf.utf8.items;

        if (std.mem.eql(u8, raw_buf, "exit")) {
            return 0;
        }

        if (std.mem.eql(u8, raw_buf, "clear")) {
            try stdout.writeAll("\x1b[2J\x1b[3J\x1b[H");
            continue;
        }

        try stdout.writeAll(buf.utf8.items);
        try stdout.writeByte('\n');
        // const exit_code = try self.zlush.execute(buf);
        // try stdout.print("exitcode: {}\n", .{exit_code});
        try stdout.flush();
    }
}

pub fn promptUser(self: *Interactive, allocator: std.mem.Allocator) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!common.Unicode.UGF8.Buffer {
    while (true) {
        const prompt_len = 7;
        const stdout = self.tty.stdoutWriter();
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
