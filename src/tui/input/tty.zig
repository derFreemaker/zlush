const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Event = @import("event.zig").Event;
const Winsize = @import("winsize.zig");
const Parser = @import("parser.zig");

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

parser: Parser,
queue: common.Queue(Event),

pub fn init(alloc: std.mem.Allocator, paste_alloc: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File, stderr: std.fs.File) error{OutOfMemory}!*Tty {
    const stdout_writer_buf = try alloc.alloc(u8, 4096);
    errdefer alloc.free(stdout_writer_buf);

    const stderr_writer_buf = try alloc.alloc(u8, 4096);
    errdefer alloc.free(stderr_writer_buf);

    var parser = try Parser.init(alloc);
    errdefer parser.deinit();

    var queue = common.Queue(Event).init(alloc, 512) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    errdefer queue.deinit(alloc);

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

        .parser = parser,
        .queue = queue,
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
    self.parser.deinit();

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
    var temp_buf: [128]u8 = undefined;
    var temp_len: usize = 0;
    var cp_last: ?u21 = null;

    while (!self.should_quit) {
        const token = try self.internal.nextToken() orelse {
            if (temp_len > 0) {
                if (temp_buf[0] != 27) {
                    const event = try self.convertGraphemeToPasteEvent(temp_buf[0..temp_len]);
                    cp_state = .{};
                    temp_len = 0;

                    self.postEvent(event);
                    continue;
                }

                const result = try self.parser.parse(temp_buf[0..temp_len], self.paste_alloc);
                if (result.event) |event| {
                    self.postEvent(event);
                }
                if (result.n > 0) {
                    @memmove(temp_buf[0..result.n], temp_buf[result.n..temp_len]);
                }
                continue;
            }

            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        if (token == .event) {
            self.queue.push(token.event);
            continue;
        }

        const cp = token.cp;

        if (temp_len > 0) {
            if (temp_buf[0] == 27) {
                const result = try self.parser.parse(temp_buf[0..temp_len], self.paste_alloc);
                if (result.event) |event| {
                    self.postEvent(event);
                }
                if (result.n > 0) {
                    @memmove(temp_buf[0..result.n], temp_buf[result.n..temp_len]);
                }
                continue;
            }

            const is_break = common.Unicode.Graphemes.graphemeBreak(cp_last.?, cp, &self.parser.graphemes, &cp_state);
            if (is_break) {
                const event = try self.convertGraphemeToPasteEvent(temp_buf[0..temp_len]);
                cp_state = .{};
                temp_len = 0;

                self.postEvent(event);
                continue;
            }
        }

        temp_len += try std.unicode.utf8Encode(cp, temp_buf[temp_len..]);
        cp_last = cp;
    }
}

fn convertGraphemeToPasteEvent(self: *Tty, slice: []const u8) !Event {
    const buf = try self.alloc.alloc(common.Unicode.UGF8.Unit, 1);
    errdefer self.alloc.free(buf);

    const dw: u7 = @intCast(self.parser.dw.strWidth(slice));
    const codepoints_count: u13 = @intCast(try std.unicode.utf8CountCodepoints(slice));
    buf[0] = common.Unicode.UGF8.Unit.init(self.alloc, slice, codepoints_count, dw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    errdefer buf[0].deinit(self.alloc);

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
