const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const AnsiColor = @import("../utils/ansi_color.zig");
const RawMode = @import("raw_mode.zig");

const Prompt = @import("input/prompt.zig");

const Interactive = @This();

allocator: std.mem.Allocator,

stdout_buf: []u8,
stdout: std.fs.File.Writer,

stderr_buf: []u8,
stderr: std.fs.File.Writer,

sw: *common.Stopwatch,

pub fn init(allocator: std.mem.Allocator, sw: *common.Stopwatch) error{ FailedToSetRawMode, OutOfMemory }!Interactive {
    try sw.begin("interactive initialize");
    defer sw.end();
    
    RawMode.enable() catch return error.FailedToSetRawMode;

    const stdout_buf = try allocator.alloc(u8, 1024);
    const stderr_buf = try allocator.alloc(u8, 1024);

    return Interactive{
        .allocator = allocator,

        .stdout_buf = stdout_buf,
        .stdout = std.fs.File.stdout().writer(stdout_buf),

        .stderr_buf = stderr_buf,
        .stderr = std.fs.File.stderr().writer(stderr_buf),
        
        .sw = sw,
    };
}

pub fn deinit(self: *Interactive) void {
    self.allocator.free(self.stdout_buf);
    self.allocator.free(self.stderr_buf);

    RawMode.disable();
}

pub fn loop(self: *Interactive) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }!u8 {
    try self.sw.display(&self.stdout.interface);
    while (true) {
        defer self.stdout.interface.flush() catch @panic("unable to flush");

        const command = self.promptUser(self.allocator) catch |err| switch (err) {
            error.EndOfInput => return 0,
            else => |e| return e,
        };
        defer self.allocator.free(command);

        if (std.mem.eql(u8, command, "exit")) {
            return 0;
        }

        if (std.mem.eql(u8, command, "clear")) {
            try self.stdout.interface.writeAll("\x1b[2J\x1b[3J\x1b[H");
            continue;
        }

        try self.stdout.interface.writeAll(command);
        try self.stdout.interface.writeByte('\n');
    }
}

pub fn promptUser(self: *Interactive, allocator: std.mem.Allocator) error{ OutOfMemory, WriteFailed, EndOfInput, ReadingCommandFailed, EchoingStateFailed }![]const u8 {
    while (true) {
        try self.stdout.interface.writeAll("zlush> ");
        try self.stdout.interface.flush();

        var prompt = try Prompt.init(self.allocator, &self.stdout.interface);
        defer prompt.deinit();

        const command = prompt.readCommand(allocator) catch |err| switch (err) {
            error.CommandCanceled => {
                try self.stdout.interface.print("{f}^C{s}\n", .{
                    AnsiColor.Coloring{
                        .foreground = .normal(.bright_red),
                    },
                    comptime AnsiColor.reset(),
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

        return command;
    }
}
