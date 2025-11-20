const std = @import("std");
const builtin = @import("builtin");

const InputToken = @import("input_token.zig").InputToken;

const Tokenizer = @This();

stdin_buf: []u8,
stdin: std.fs.File.Reader,

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Tokenizer {
    const stdin_buf = try allocator.alloc(u8, 256);

    return Tokenizer{
        .stdin_buf = stdin_buf,
        .stdin = std.fs.File.stdin().reader(stdin_buf),
    };
}

pub fn deinit(self: *Tokenizer, allocator: std.mem.Allocator) void {
    allocator.free(self.stdin_buf);
}

pub fn nextToken(self: *Tokenizer) error{ EndOfStream, ReadFailed }!InputToken {
    var c: u21 = 0;
    while (c == 0) {
        if (self.peekCodepoint() catch |err| switch (err) {
            error.InvalidUTF8 => return .invalid,
            error.EndOfStream => return .EOF,
            error.ReadFailed => return error.ReadFailed,
        }) |pC| {
            c = pC;
        }
    }

    switch (c) {
        '\r' => {
            self.tossCodepoint(c);

            if (self.peekCodepoint() catch |err| switch (err) {
                error.InvalidUTF8 => return .invalid,
                error.EndOfStream => return .EOF,
                error.ReadFailed => return error.ReadFailed,
            }) |c2| {
                if (c2 == '\n') {
                    self.tossCodepoint(c2);
                    return .newline;
                }
            }

            return .newline;
        },
        '\n' => {
            self.tossCodepoint(c);
            return .newline;
        },

        8 => {
            self.tossCodepoint(c);
            return .backspace;
        },
        127 => {
            self.tossCodepoint(c);
            return .delete;
        },
        
        3 => { // ctrl+c
            self.tossCodepoint(c);
            return .interrupt;
        },
        4 => { // ctrl+d (EOF)
            self.tossCodepoint(c);
            return .EOF;
        },
        12 => { // ctrl+l (clear screen)
            self.tossCodepoint(c);            
            return .clearScreen;
        },

        else => {
            self.tossCodepoint(c);

            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch unreachable;

            return InputToken{
                .char = InputToken.Char{
                    .buf = buf,
                    .len = len,
                },
            };
        },
    }
}

fn peekCodepoint(self: *Tokenizer) error{ InvalidUTF8, EndOfStream, ReadFailed }!?u21 {
    if (!hasStdinData()) return null;

    const byte = try self.stdin.interface.peekByte();

    switch (std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUTF8) {
        1 => {
            return @intCast(byte);
        },
        2 => {
            const bytes = (try self.stdin.interface.peekArray(2)).*;
            return std.unicode.utf8Decode2(bytes) catch unreachable;
        },
        3 => {
            const bytes = (try self.stdin.interface.peekArray(3)).*;
            return std.unicode.utf8Decode3(bytes) catch unreachable;
        },
        4 => {
            const bytes = (try self.stdin.interface.peekArray(4)).*;
            return std.unicode.utf8Decode4(bytes) catch unreachable;
        },
        else => unreachable,
    }
}

fn tossCodepoint(self: *Tokenizer, c: u21) void {
    self.stdin.interface.toss(std.unicode.utf8CodepointSequenceLength(c) catch unreachable);
}

// fn parseGrapheme(self: *Tokenizer, c: u21)

fn hasStdinData() bool {
    if (builtin.os.tag == .windows) {
        const c = @cImport({
            @cInclude("conio.h");
        });

        return c.kbhit() == 1;
    } else {
        const posix = std.posix;
        var pollfds = comptime [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try posix.poll(&pollfds, 0);

        return ready > 0 and (pollfds[0].revents & posix.POLL.IN) != 0;
    }
}
