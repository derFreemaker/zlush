const std = @import("std");
const builtin = @import("builtin");

const AnsiColor = @import("../utils/ansi_color.zig");
const RawMode = @import("raw_mode.zig");

const InputToken = @import("input/input_token.zig").InputToken;
const ConsoleReader = if (builtin.os.tag == .windows) @import("input/win_console_reader.zig") else @compileError("not implemented");

const Interactive = @This();

allocator: std.mem.Allocator,

tokenizer: ConsoleReader,

stdout_buf: []u8,
stdout: std.fs.File.Writer,

stderr_buf: []u8,
stderr: std.fs.File.Writer,

pub fn init(allocator: std.mem.Allocator) error{ FailedToSetRawMode, OutOfMemory }!Interactive {
    RawMode.enable() catch return error.FailedToSetRawMode;

    const stdout_buf = try allocator.alloc(u8, 1024);
    const stderr_buf = try allocator.alloc(u8, 1024);

    return Interactive{
        .allocator = allocator,

        .tokenizer = ConsoleReader.init(allocator),

        .stdout_buf = stdout_buf,
        .stdout = std.fs.File.stdout().writer(stdout_buf),

        .stderr_buf = stderr_buf,
        .stderr = std.fs.File.stderr().writer(stderr_buf),
    };
}

pub fn deinit(self: *Interactive) void {
    self.allocator.free(self.stdout_buf);
    self.allocator.free(self.stderr_buf);

    self.tokenizer.deinit(self.allocator);

    RawMode.disable();
}

pub fn loop(self: *Interactive) !u8 {
    while (true) {
        defer self.stdout.interface.flush() catch @panic("unable to flush");

        const command = self.promptUser(self.allocator) catch |err| switch (err) {
            error.EndOfStream => return 0,
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

pub fn promptUser(self: *Interactive, allocator: std.mem.Allocator) ![]const u8 {
    while (true) {
        try self.stdout.interface.writeAll("zlush> ");
        try self.stdout.interface.flush();

        const command = self.readCommand(allocator) catch |err| switch (err) {
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
            else => return err,
        };

        return command;
    }
}

fn redraw(self: *Interactive, tokens: []const InputToken, cursor: u32, after_cursor: u32) !void {
    self.stdout.interface.print("\x1b[{}D\x1b[0K", .{cursor}) catch return error.EchoingStateFailed;
    for (tokens) |t| {
        switch (t) {
            .char => |c| {
                self.stdout.interface.writeAll(c.get()) catch return error.EchoingStateFailed;
            },
            .space => {
                self.stdout.interface.writeByte(' ') catch return error.EchoingStateFailed;
            },
            else => {},
        }
    }
    const move_left = tokens.len - after_cursor;
    if (move_left > 0) {
        self.stdout.interface.print("\x1b[{}D", .{move_left}) catch return error.EchoingStateFailed;
    }
}

pub fn readCommand(self: *Interactive, allocator: std.mem.Allocator) error{ ReadingCommandFailed, EndOfStream, OutOfMemory, CommandCanceled, CommandCanceledAndClear, EchoingStateFailed }![]const u8 {
    var tokens: std.ArrayListUnmanaged(InputToken) = try .initCapacity(allocator, 256);
    defer {
        for (tokens.items) |*token| {
            token.deinit();
        }
        tokens.deinit(allocator);
    }
    var cursor: u32 = 0;

    while (true) {
        const token = self.tokenizer.nextToken(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadingCommandFailed,
            // error.EndOfStream => return error.EndOfStream,
        };
        // std.debug.print("{any}\n", .{ token });

        switch (token) {
            .char => |c| {
                try tokens.insert(allocator, cursor, token);
                cursor += 1;

                self.stdout.interface.writeAll(c.get()) catch return error.EchoingStateFailed;
                if (tokens.items.len != cursor) {
                    try self.redraw(tokens.items, cursor, cursor);
                }
                self.stdout.interface.flush() catch return error.EchoingStateFailed;
            },
            .space => {
                try tokens.insert(allocator, cursor, token);
                cursor += 1;

                self.stdout.interface.writeByte(' ') catch return error.EchoingStateFailed;
                if (tokens.items.len != cursor) {
                    try self.redraw(tokens.items, cursor, cursor);
                }
                self.stdout.interface.flush() catch return error.EchoingStateFailed;
            },
            .enter => {
                self.stdout.interface.writeByte('\n') catch return error.EchoingStateFailed;
                self.stdout.interface.flush() catch return error.EchoingStateFailed;
                break;
            },

            .backspace => {
                if (cursor == 0) {
                    continue;
                }

                cursor -= 1;
                var removed_token = tokens.orderedRemove(cursor);
                removed_token.deinit();

                if (tokens.items.len == cursor) {
                    self.stdout.interface.writeAll("\x08\x1b[0K") catch return error.EchoingStateFailed;
                } else {
                    try self.redraw(tokens.items, cursor + 1, cursor);
                }

                self.stdout.interface.flush() catch return error.EchoingStateFailed;
            },

            .interrupt => {
                return error.CommandCanceled;
            },

            .EOF => {
                return error.EndOfStream;
            },

            .clearScreen => {
                return error.CommandCanceledAndClear;
            },

            .right => {
                if (cursor < tokens.items.len) {
                    cursor += 1;
                    self.stdout.interface.writeAll("\x1b[1C") catch return error.EchoingStateFailed;
                    self.stdout.interface.flush() catch return error.EchoingStateFailed;
                }
            },
            .left => {
                if (cursor > 1) {
                    cursor -= 1;
                    self.stdout.interface.writeAll("\x1b[1D") catch return error.EchoingStateFailed;
                    self.stdout.interface.flush() catch return error.EchoingStateFailed;
                }
            },

            else => {
                // std.debug.print("token ignored\n", .{});
            },
        }
    }

    var command_writer = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
    defer command_writer.deinit();

    for (tokens.items) |token| {
        switch (token) {
            .char => |c| {
                command_writer.writer.writeAll(c.get()) catch return error.ReadingCommandFailed;
            },
            .space => {
                command_writer.writer.writeByte(' ') catch return error.ReadingCommandFailed;
            },
            else => unreachable,
        }
    }

    return try allocator.dupe(u8, command_writer.written());
}
