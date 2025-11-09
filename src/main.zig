const std = @import("std");
const builtin = @import("builtin");

const Signal = @import("signal.zig");
const Ansi = @import("utils/ansi.zig");

const Zlush = @import("zlush");

pub fn main() !u8 {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();

    var gpa = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{
        .retain_metadata = true,
        .never_unmap = true,
    }){
        .backing_allocator = arena_allocator.allocator(),
    } else void{};
    defer if (builtin.mode == .Debug) if (gpa.deinit() == .leak) @panic("leaks detected");
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else arena_allocator.allocator();

    var interactive = try ZlushInteractive.init(allocator);
    defer interactive.deinit();
    return interactive.loop();
}

const ZlushInteractive = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    stdin_buf: []u8,
    stdin: std.fs.File.Reader,

    stdout_buf: []u8,
    stdout: std.fs.File.Writer,

    stderr_buf: []u8,
    stderr: std.fs.File.Writer,

    pub fn init(allocator: std.mem.Allocator) error{ FailedToSetHandler, OutOfMemory }!Self {
        try Signal.initSigHandler();

        const stdin_buf = try allocator.alloc(u8, 256);
        const stdout_buf = try allocator.alloc(u8, 1024);
        const stderr_buf = try allocator.alloc(u8, 1024);

        return Self{
            .allocator = allocator,

            .stdin_buf = stdin_buf,
            .stdin = std.fs.File.stdin().reader(stdin_buf),

            .stdout_buf = stdout_buf,
            .stdout = std.fs.File.stdout().writer(stdout_buf),

            .stderr_buf = stderr_buf,
            .stderr = std.fs.File.stderr().writer(stderr_buf),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.stdin_buf);
        self.allocator.free(self.stdout_buf);
        self.allocator.free(self.stderr_buf);
    }

    pub fn loop(self: *Self) !u8 {
        while (true) {
            defer self.stdout.interface.flush() catch @panic("unable to flush");

            const command = try self.promptUser(self.allocator);
            defer self.allocator.free(command);

            if (std.mem.eql(u8, command, "exit")) {
                return 0;
            }

            if (std.mem.eql(u8, command, "clear")) {
                try self.stdout.interface.writeAll("\x1b[H\x1b[2J");
                continue;
            }

            if (std.mem.eql(u8, command, "clear --scrollback")) {
                try self.stdout.interface.writeAll("\x1b[3J\x1b[H\x1b[2J");
                continue;
            }

            try self.stdout.interface.writeAll(command);
            try self.stdout.interface.writeByte('\n');
        }
    }
    
    pub fn promptUser(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        while (true) {
            try self.stdout.interface.writeAll("zlush> ");
            try self.stdout.interface.flush();

            const command = self.readCommand(allocator) catch |err| switch (err) {
                error.CommandCanceled => {
                    try self.stdout.interface.print("{f}^C{s}\n", .{
                        Ansi.Coloring{
                            .foreground = .normal(.bright_red),
                        },
                        comptime Ansi.reset(),
                    });
                    try self.stdout.interface.flush();
                    continue;
                },
                else => return err,
            };

            return command;
        }
    }

    pub fn readCommand(self: *Self, allocator: std.mem.Allocator) error{ ReadingCommandFailed, EndOfStream, OutOfMemory, CommandCanceled }![]const u8 {
        Signal.reset(.INTERRUPT);

        var command_writer = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer command_writer.deinit();

        while (true) {
            if (Signal.found(.INTERRUPT)) {
                return error.CommandCanceled;
            }

            const has_data = hasStdinData(30) catch unreachable;

            if (has_data) {
                const byte = self.stdin.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => continue,
                    else => return error.ReadingCommandFailed,
                };

                if (byte == '\n') {
                    break;
                }
                command_writer.writer.writeByte(byte) catch return error.ReadingCommandFailed;
            }
        }

        const command_buf = command_writer.written();
        const command = if (std.mem.endsWith(u8, command_buf, "\r")) command_buf[0 .. command_writer.written().len - 1] else command_buf;
        return try allocator.dupe(u8, command);
    }

    fn hasStdinData(timeout_ms: i32) !bool {
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const stdin_handle = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);

            const timeout: u32 = if (timeout_ms < 0) windows.INFINITE else @intCast(timeout_ms);

            windows.WaitForSingleObject(stdin_handle, timeout) catch |err| switch (err) {
                error.WaitTimeOut => return false,
                else => return error.WaitFailed,
            };

            return true;
        } else {
            const posix = std.posix;
            var pollfds = [_]posix.pollfd{.{
                .fd = posix.STDIN_FILENO,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = try posix.poll(&pollfds, timeout_ms);

            return ready > 0 and (pollfds[0].revents & posix.POLL.IN) != 0;
        }
    }
};
