const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Event = @import("event.zig").Event;
const Winsize = @import("winsize.zig");

const InternalTty = if (builtin.target.os.tag == .windows)
    @import("tty/win_tty.zig")
else
    @compileError("not implemented");

const Tty = @This();

alloc: std.mem.Allocator,
paste_alloc: std.mem.Allocator,

stdin: std.fs.File,
stdout: std.fs.File,
stderr: std.fs.File,

stdout_writer_buf: []u8,
stdout_writer: std.fs.File.Writer,

stderr_writer_buf: []u8,
stderr_writer: std.fs.File.Writer,

internal: InternalTty,
thread: ?std.Thread = null,
should_quit: bool = false,

graphemes: common.Unicode.Graphemes,
dw: common.Unicode.DisplayWidth,

queue: common.Queue(Event),

pub fn init(alloc: std.mem.Allocator, paste_alloc: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File, stderr: std.fs.File) error{OutOfMemory}!*Tty {
    const stdout_writer_buf = try alloc.alloc(u8, 4096);
    errdefer alloc.free(stdout_writer_buf);

    const stderr_writer_buf = try alloc.alloc(u8, 4096);
    errdefer alloc.free(stderr_writer_buf);

    const graphemes = try common.Unicode.Graphemes.init(alloc);

    const ptr = try alloc.create(Tty);
    ptr.* = Tty{
        .alloc = alloc,
        .paste_alloc = paste_alloc,

        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,

        .stdout_writer_buf = stdout_writer_buf,
        .stdout_writer = std.fs.File.Writer.initStreaming(stdout, stdout_writer_buf),

        .stderr_writer_buf = stderr_writer_buf,
        .stderr_writer = std.fs.File.Writer.initStreaming(stderr, stderr_writer_buf),

        .internal = InternalTty.init(stdin.handle, stdout.handle),

        .graphemes = graphemes,
        .dw = try common.Unicode.DisplayWidth.initWithGraphemes(alloc, graphemes),

        .queue = common.Queue(Event).init(alloc, 512) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        },
    };
    return ptr;
}

pub fn deinit(self: *Tty) void {
    self.stop();

    self.stdoutWriter().flush() catch {};
    self.stderrWriter().flush() catch {};

    self.internal.deinit();

    self.alloc.free(self.stdout_writer_buf);
    self.alloc.free(self.stderr_writer_buf);

    self.queue.deinit(self.alloc);

    self.dw.deinit(self.alloc);
    self.graphemes.deinit(self.alloc);

    self.alloc.destroy(self);
}

pub fn getWindowSize(self: *Tty) error{Unexpected}!Winsize {
    return InternalTty.getWindowSize(self.stdout.handle);
}

pub fn start(self: *Tty) std.Thread.SpawnError!void {
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, runTty, .{
        self,
    });
}

pub fn stop(self: *Tty) void {
    const thread = self.thread orelse return;

    self.should_quit = true;
    thread.join();

    self.thread = null;
    self.should_quit = false;
}

pub fn stdoutWriter(self: *Tty) *std.Io.Writer {
    return &self.stdout_writer.interface;
}

pub fn stderrWriter(self: *Tty) *std.Io.Writer {
    return &self.stderr_writer.interface;
}

pub fn postEvent(self: *Tty, event: Event) void {
    self.queue.push(event);
}

pub fn tryPostEvent(self: *Tty, event: Event) bool {
    return self.queue.tryPush(event);
}

pub fn nextEvent(self: *Tty) Event {
    return self.queue.pop();
}

fn runTty(self: *Tty) !void {
    if (builtin.is_test) return;

    var cp_state: common.Unicode.Graphemes.IterState = .{};
    var cp_buf: [64]u21 = undefined;
    var cp_len: usize = 0;

    while (!self.should_quit) {
        const token = try self.internal.nextToken() orelse {
            if (cp_len > 0) {
                if (cp_buf[0] == 27) {
                    // found escape sequence

                    @panic("not implemented");
                }

                const event = try self.convertGraphemeCodepointsToPasteEvent(cp_buf[0..cp_len]);
                cp_state = .{};
                cp_len = 0;

                self.postEvent(event);
            }

            continue;
        };
        if (token == .event) {
            self.queue.push(token.event);
            continue;
        }

        const cp = token.cp;

        if (cp_len > 0) {
            if (cp_buf[0] == 27) {
                // found escape sequence

                @panic("not implemented");
            }

            const is_break = common.Unicode.Graphemes.graphemeBreak(cp_buf[cp_len - 1], cp, &self.graphemes, &cp_state);
            if (is_break) {
                const event = try self.convertGraphemeCodepointsToPasteEvent(cp_buf[0..cp_len]);
                cp_state = .{};
                cp_len = 0;

                self.postEvent(event);
            }
        }

        cp_buf[cp_len] = cp;
        cp_len += 1;
    }
}

fn convertGraphemeCodepointsToPasteEvent(self: *Tty, codepoints: []const u21) error{OutOfMemory}!Event {
    const dw: u7 = @intCast(self.dw.codePointsWidth(codepoints));
    const unit = common.Unicode.UGF.Unit.init(self.alloc, codepoints, dw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const buf = try self.alloc.alloc(common.Unicode.UGF.Unit, 1);
    buf[0] = unit;

    return Event{
        .paste = .{
            .alloc = self.paste_alloc,
            .buf = buf,
        },
    };
}

pub const TtyToken = union(enum) {
    event: Event,
    cp: u21,
};
