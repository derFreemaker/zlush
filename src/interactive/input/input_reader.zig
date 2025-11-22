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

cache: GraphemeCache,
graphemes: common.unicode.Graphemes,
dw: common.unicode.DisplayWidth,

queue: common.Queue(Event),

thread: ?std.Thread = null,
should_quit: bool = false,

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*InputReader {
    const graphemes = try common.unicode.Graphemes.init(allocator);

    const ptr = try allocator.create(InputReader);
    ptr.* = InputReader{
        .allocator = allocator,

        .reader = ConsoleReader.init(),

        .cache = try .init(allocator),
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

    self.cache.deinit(self.allocator);
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

fn runReader(self: *InputReader) !void {
    if (builtin.is_test) return;

    var cp_state: common.unicode.Graphemes.IterState = .{};
    var cp_buf: [32]u21 = undefined;
    var cp_len: usize = 0;
    
    while (!self.should_quit) {
        const token = blk: {
            if (try self.reader.nextToken()) |token| {
                break :blk token;
            }

            if (cp_len > 0) {
                const event = self.convertCodepointsToGraphemeEvent(cp_buf[0..cp_len]);
                cp_state = .{};
                cp_len = 0;

                self.postEvent(event);
            }

            continue;
        };

        switch (token) {
            .cp => |cp| {
                if (cp_len > 0) {
                    const is_break = common.unicode.Graphemes.graphemeBreak(cp_buf[cp_len - 1], cp, &self.graphemes, &cp_state);
                    if (is_break) {
                        const event = self.convertCodepointsToGraphemeEvent(cp_buf[0..cp_len]);
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
                    const grapheme_event = self.convertCodepointsToGraphemeEvent(cp_buf[0..cp_len]);
                    cp_state = .{};
                    cp_len = 0;

                    self.postEvent(grapheme_event);
                }

                self.postEvent(event);
            },
        }
    }
}

fn convertCodepointsToGraphemeEvent(self: *InputReader, code_points: []const u21) Event {
    var required_len: usize = 0;
    for (code_points) |cp| {
        required_len += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
    }

    const buf = self.cache.get(required_len);
    var buf_idx: usize = 0;
    for (code_points) |cp| {
        buf_idx += std.unicode.utf8Encode(cp, buf[buf_idx..]) catch unreachable;
    }

    return Event{ .grapheme = .{ .cluster = .{
        .data = buf,
        .dw = @intCast(self.dw.strWidth(buf)),
    } } };
}

pub const ReadToken = union(enum) {
    event: Event,
    cp: u21,
};
