const std = @import("std");
const builtin = @import("builtin");

const Event = @import("event.zig");

const InternalTty = if (builtin.target.os.tag == .windows)
    @import("tty/win_tty.zig")
else
    @compileError("not implemented");

const Tty = @This();

alloc: std.mem.Allocator,

stdin: std.fs.File,
stdout: std.fs.File,
stderr: std.fs.File,

stdout_writer_buf: []u8,
stdout_writer: std.fs.File.Writer,

stderr_writer_buf: []u8,
stderr_writer: std.fs.File.Writer,

internal: InternalTty,

pub fn init(alloc: std.mem.Allocator) error{OutOfMemory}!Tty {
    const stdin: std.fs.File = .stdin();
    const stdout: std.fs.File = .stdout();
    const stderr: std.fs.File = .stderr();

    const stdout_writer_buf = try alloc.alloc(u8, 1024);
    defer alloc.free(stdout_writer_buf);

    const stderr_writer_buf = try alloc.alloc(u8, 1024);
    defer alloc.free(stderr_writer_buf);

    return Tty{
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,

        .stdout_writer_buf = stdout_writer_buf,
        .stdout_writer = std.fs.File.Writer.initStreaming(stdout, stdout_writer_buf),

        .stderr_writer_buf = stderr_writer_buf,
        .stderr_writer = std.fs.File.Writer.initStreaming(stderr, stderr_writer_buf),

        .internal = InternalTty.init(stdin.handle, stdout.handle),
    };
}

pub fn deinit(self: *Tty) void {
    self.stdoutWriter().flush() catch {};
    self.stderrWriter().flush() catch {};

    self.alloc.free(self.stdout_writer_buf);
    self.alloc.free(self.stderr_writer_buf);
}

pub fn stdoutWriter(self: *Tty) *std.Io.Writer {
    return &self.stdout_writer.interface;
}

pub fn stderrWriter(self: *Tty) *std.Io.Writer {
    return &self.stderr_writer.interface;
}

pub const TtyToken = struct {
    event: Event,
    cp: u21,
};
