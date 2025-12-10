const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Zlush = @import("zlush");

const RawMode = @import("raw_mode.zig");

const InputReader = @import("input/input_reader.zig");
const Prompt = @import("input/prompt.zig");

const Interactive = @This();

allocator: std.mem.Allocator,

stdout_buf: []u8,
stdout: std.fs.File.Writer,

stderr_buf: []u8,
stderr: std.fs.File.Writer,

reader: *InputReader,

zlush: Zlush,

sw: *common.Stopwatch,

pub fn init(allocator: std.mem.Allocator, sw: *common.Stopwatch) error{ FailedToSetRawMode, OutOfMemory }!Interactive {
    try sw.begin("initialize interactive");
    defer sw.end();

    RawMode.enable() catch return error.FailedToSetRawMode;

    const stdout_buf = try allocator.alloc(u8, 1024);
    const stderr_buf = try allocator.alloc(u8, 1024);

    const reader = blk: {
        try sw.begin("start input reader");
        defer sw.end();

        const reader = try InputReader.init(allocator);
        reader.start() catch @panic("unable to start console reader thread");
        break :blk reader;
    };

    return Interactive{
        .allocator = allocator,

        .stdout_buf = stdout_buf,
        .stdout = std.fs.File.stdout().writer(stdout_buf),

        .stderr_buf = stderr_buf,
        .stderr = std.fs.File.stderr().writer(stderr_buf),

        .reader = reader,

        .zlush = try .init(allocator, sw),

        .sw = sw,
    };
}

pub fn deinit(self: *Interactive) void {
    self.reader.deinit();

    self.allocator.free(self.stdout_buf);
    self.allocator.free(self.stderr_buf);

    RawMode.disable();
}

pub fn loop(self: *Interactive) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!u8 {
    try self.sw.display(&self.stdout.interface);
    while (true) {
        defer self.stdout.interface.flush() catch @panic("unable to flush");

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
            try self.stdout.interface.writeAll("\x1b[2J\x1b[3J\x1b[H");
            continue;
        }

        try self.stdout.interface.writeAll(buf.utf8.items);
        try self.stdout.interface.writeByte('\n');
        // const exit_code = try self.zlush.execute(buf);
        // try self.stdout.interface.print("exitcode: {}\n", .{exit_code});
        try self.stdout.interface.flush();
    }
}

pub fn promptUser(self: *Interactive, allocator: std.mem.Allocator) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!common.Unicode.UGF8.Buffer {
    while (true) {
        const prompt_len = 7;
        try self.stdout.interface.writeAll("zlush> ");
        try self.stdout.interface.flush();

        var prompt = try Prompt.init(self.allocator, self.reader, &self.stdout.interface, prompt_len);
        defer prompt.deinit();

        const buf = prompt.readCommand(allocator) catch |err| switch (err) {
            error.CommandCanceled => {
                try self.stdout.interface.print("{f}^C{s}\n", .{
                    common.AnsiColor.Coloring{
                        .foreground = .normal(.bright_red),
                    },
                    comptime common.AnsiColor.reset(),
                });
                try self.stdout.interface.flush();
                continue;
            },
            error.CommandCanceledAndClear => {
                try self.stdout.interface.writeAll("\x1b[2J\x1b[3J\x1b[H");
                try self.stdout.interface.flush();
                continue;
            },
            else => |e| return e,
        };

        return buf;
    }
}
