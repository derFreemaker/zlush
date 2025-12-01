const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const GraphemeCache = @import("grapheme_cache.zig");
const Event = @import("event.zig").Event;

const ConsoleReader =
    if (builtin.is_test)
        @compileError("tests not supported")
    else if (builtin.os.tag == .windows)
        @import("win_console_reader.zig")
    else
        @compileError("not implemented");

const InputReader = @This();

allocator: std.mem.Allocator,

reader: ConsoleReader,

// cache: GraphemeCache,
graphemes: common.Unicode.Graphemes,
dw: common.Unicode.DisplayWidth,

queue: common.Queue(Event),

thread: ?std.Thread = null,
should_quit: bool = false,

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*InputReader {
    const graphemes = try common.Unicode.Graphemes.init(allocator);

    const ptr = try allocator.create(InputReader);
    ptr.* = InputReader{
        .allocator = allocator,

        .reader = ConsoleReader.init(),

        // .cache = try .init(allocator),
        .graphemes = graphemes,
        .dw = try .initWithGraphemes(allocator, graphemes),

        .queue = common.Queue(Event).init(allocator, 256) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SizeTooBig => unreachable,
        },
    };
    return ptr;
}

pub fn deinit(self: *InputReader) void {
    self.stop();

    self.reader.deinit();

    // self.cache.deinit(self.allocator);
    self.dw.deinit(self.allocator);
    self.graphemes.deinit(self.allocator);

    self.queue.deinit(self.allocator);

    self.allocator.destroy(self);
}

pub fn start(self: *InputReader) std.Thread.SpawnError!void {
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, InputReader.runReader, .{
        self,
    });
}

pub fn stop(self: *InputReader) void {
    if (self.thread == null) return;

    self.should_quit = true;
    const thread = self.thread.?;
    thread.join();

    self.thread = null;
    self.should_quit = false;
}

pub fn nextEvent(self: *InputReader) Event {
    return self.queue.pop();
}

pub fn postEvent(self: *InputReader, event: Event) void {
    self.queue.push(event);
}

pub fn getWindowSize(self: *InputReader) !Event.Winsize {
    return self.reader.getWindowSize();
}

fn runReader(self: *InputReader) !void {
    if (builtin.is_test) return;

    var cp_state: common.Unicode.Graphemes.IterState = .{};
    var cp_buf: [32]u21 = undefined;
    var cp_len: usize = 0;

    while (!self.should_quit) {
        const token = blk: {
            if (try self.reader.nextToken()) |token| {
                break :blk token;
            }

            if (cp_len > 0) {
                const event = try self.convertCodepointsToGraphemeEvent(cp_buf[0..cp_len]);
                cp_state = .{};
                cp_len = 0;

                self.postEvent(event);
            }

            continue;
        };

        switch (token) {
            .cp => |cp| {
                if (cp_len > 0) {
                    const is_break = common.Unicode.Graphemes.graphemeBreak(cp_buf[cp_len - 1], cp, &self.graphemes, &cp_state);
                    if (is_break) {
                        const event = try self.convertCodepointsToGraphemeEvent(cp_buf[0..cp_len]);
                        cp_state = .{};
                        cp_len = 0;

                        self.postEvent(event);
                    }
                }

                cp_buf[cp_len] = cp;
                cp_len += 1;
                continue;
            },
            .event => |event| {
                if (cp_len > 0) {
                    const grapheme_event = try self.convertCodepointsToGraphemeEvent(cp_buf[0..cp_len]);
                    cp_state = .{};
                    cp_len = 0;

                    self.postEvent(grapheme_event);
                }

                self.postEvent(event);
            },
        }
    }
}

fn convertCodepointsToGraphemeEvent(self: *InputReader, codepoints: []const u21) error{OutOfMemory}!Event {
    if (codepoints.len == 1) {
        const cp = codepoints[0];
        return Event{ .grapheme = common.Unicode.UGF.Unit.initSingle(cp, @intCast(self.dw.codePointWidth(cp))) };
    }

    const dw: u7 = @intCast(self.dw.codePointsWidth(codepoints));
    return Event{
        .grapheme = common.Unicode.UGF.Unit.init(self.allocator, codepoints, dw) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => |e| std.debug.panic("{s}", .{@errorName(e)}),
        },
    };
}

pub const ReadToken = union(enum) {
    event: Event,
    cp: u21,
};
