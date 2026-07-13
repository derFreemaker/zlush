const std = @import("std");
const testing = std.testing;

pub const Token = union(enum) {
    separator,
    short_option: ShortOption,
    option: Option,
    arg: []const u8,

    pub const ShortOption = struct {
        name: u8,
        value: ?[]const u8,
    };

    pub const Option = struct {
        name: []const u8,
        value: ?[]const u8,
    };
};

/// `arg`
/// `--` (separator)
/// `-f`
/// `-f=value`
/// `-f=`
/// `-fgh` -> `-f`, `-g`, `-h`
/// `-fgh=value` -> `-f=value`, `-g=value`, `-h=value`
/// `-fgh=` -> `-f=`, `-g=`, `-h=`
/// `--option`
/// `--option=value`
/// `--option=`
const Tokenizer = @This();

args: []const []const u8,
index: usize = 0,

state: State = .none,
next_token: ?Token = null,

pub fn init(args: []const []const u8) Tokenizer {
    return Tokenizer{
        .args = args,
    };
}

pub fn remaining(self: *const Tokenizer) []const []const u8 {
    return self.args[self.index - if (self.next_token == null) @as(usize, 0) else @as(usize, 1) ..];
}

inline fn nextRaw(self: *Tokenizer) ?[]const u8 {
    if (self.index >= self.args.len) {
        return null;
    }
    defer self.index += 1;

    return self.args[self.index];
}

pub fn peek(self: *Tokenizer) ?Token {
    if (self.next_token) |token| {
        return token;
    }

    switch (self.state) {
        .none => {},
        .in_short_options => |*s_opts| {
            const token = Token{ .short_option = .{
                .name = s_opts.remaining[0],
                .value = s_opts.value,
            } };

            if (s_opts.remaining.len == 1) {
                self.state = .none;
            } else {
                s_opts.remaining = s_opts.remaining[1..];
            }

            return token;
        },
    }

    const arg = while (self.nextRaw()) |arg| {
        if (arg.len >= 1) {
            break arg;
        }
    } else {
        return null;
    };

    var token: Token = undefined;
    if (arg[0] == '-') {
        token = if (arg.len > 1 and arg[1] == '-')
            tokenizeLongOption(arg)
        else
            self.tokenizeShortOption(arg);
    } else {
        token = Token{ .arg = arg };
    }

    self.next_token = token;
    return token;
}

pub fn toss(self: *Tokenizer) void {
    if (self.next_token != null) {
        self.next_token = null;
        return;
    }

    _ = self.next();
}

pub fn undo(self: *Tokenizer, n: usize) void {
    if (n == 0) {
        return;
    }

    if (self.next_token != null) {
        self.next_token = null;
        n += 1;
    }

    self.index -|= n;
}

pub fn next(self: *Tokenizer) ?Token {
    if (self.next_token) |token| {
        self.next_token = null;
        return token;
    }

    if (self.peek()) |token| {
        self.next_token = null;
        return token;
    }

    return null;
}

inline fn tokenizeLongOption(arg: []const u8) Token {
    if (arg.len == 2) {
        // we got "--"
        return .separator;
    }
    var name = arg[2..];

    if (std.mem.indexOfScalar(u8, arg, '=') orelse
        std.mem.indexOfScalar(u8, arg, ' ')) |value_sep_idx|
    {
        name = name[0 .. value_sep_idx - 2];
        if (name.len == 0) {
            // we got no name: "--=..."
            return Token{ .arg = arg };
        }

        const value = if (arg.len - value_sep_idx - 1 > 0)
            arg[value_sep_idx + 1 ..]
        else
            null;

        return Token{ .option = .{
            .name = name,
            .value = value,
        } };
    }

    return Token{ .option = .{
        .name = name,
        .value = null,
    } };
}

inline fn tokenizeShortOption(self: *Tokenizer, arg: []const u8) Token {
    if (arg.len == 1) {
        // we got "-"
        return Token{ .arg = arg };
    }
    var name = arg[1..];

    if (std.mem.indexOfScalar(u8, arg, '=') orelse
        std.mem.indexOfScalar(u8, arg, ' ')) |value_sep_idx|
    {
        name = name[0 .. value_sep_idx - 1];
        if (name.len == 0) {
            // we got no name: "-=..."
            return Token{ .arg = arg };
        }

        const value = if (arg.len - value_sep_idx - 1 > 0)
            arg[value_sep_idx + 1 ..]
        else
            null;

        if (name.len > 1) {
            self.state = State{ .in_short_options = .{
                .remaining = name[1..],
                .value = value,
            } };
        }

        return Token{ .short_option = .{
            .name = name[0],
            .value = value,
        } };
    }

    if (name.len > 1) {
        self.state = State{ .in_short_options = .{
            .remaining = name[1..],
            .value = null,
        } };
    }

    return Token{ .short_option = .{
        .name = name[0],
        .value = null,
    } };
}

const State = union(enum) {
    none: void,
    in_short_options: struct {
        remaining: []const u8,
        value: ?[]const u8,
    },
};

fn dumpToken(token: Token) void {
    std.debug.print(".{{", .{});
    switch (token) {
        .separator => std.debug.print(" .separator ('--')", .{}),
        .arg => |arg| std.debug.print(" .arg = \"{s}\"", .{arg}),
        .short_option => |s_opt| {
            std.debug.print(" .name = '{c}', .value = ", .{s_opt.name});
            if (s_opt.value) |value| {
                std.debug.print("\"{s}\"", .{value});
            } else {
                std.debug.print("null", .{});
            }
        },
        .option => |opt| {
            std.debug.print(" .name = '{s}', .value = ", .{opt.name});
            if (opt.value) |value| {
                std.debug.print("\"{s}\"", .{value});
            } else {
                std.debug.print("null", .{});
            }
        },
    }
    std.debug.print(" }}", .{});
}

fn testTokenize(args: []const []const u8, expected_tokens: []const Token) !void {
    var tokenizer = Tokenizer.init(args);

    var i: usize = 0;
    while (tokenizer.next()) |actual| {
        if (expected_tokens.len <= i) {
            return error.FoundMoreTokensThanExpected;
        }
        const expected = expected_tokens[i];
        errdefer {
            std.debug.print("expected: ", .{});
            dumpToken(expected);
            std.debug.print(", actual: ", .{});
            dumpToken(actual);
            std.debug.print("\n", .{});
        }

        if (std.meta.activeTag(actual) != std.meta.activeTag(expected)) {
            return error.ExpectedSameTokenType;
        }
        switch (expected) {
            .separator => {},
            .arg => try testing.expectEqualStrings(expected.arg, actual.arg),
            .short_option => {
                const expected_short = expected.short_option;
                const actual_short = actual.short_option;

                if (expected_short.name != actual_short.name) {
                    return error.ExpectedDifferentShortOptionName;
                }

                if (expected_short.value == null and actual_short.value != null) {
                    return error.ExpectedNoValueInShortOption;
                } else if (expected_short.value != null and actual_short.value == null) {
                    return error.ExpectedValueInShortOption;
                } else if (expected_short.value != null) {
                    try testing.expectEqualStrings(
                        expected_short.value.?,
                        actual_short.value.?,
                    );
                }
            },
            .option => {
                const expected_opt = expected.option;
                const actual_opt = actual.option;

                try testing.expectEqualStrings(
                    expected_opt.name,
                    actual_opt.name,
                );

                if (expected_opt.value == null and actual_opt.value != null) {
                    return error.ExpectedNoValueInShortOption;
                } else if (expected_opt.value != null and actual_opt.value == null) {
                    return error.ExpectedValueInShortOption;
                } else if (expected_opt.value != null) {
                    try testing.expectEqualStrings(
                        expected_opt.value.?,
                        actual_opt.value.?,
                    );
                }
            },
        }

        i += 1;
    }

    if (i < expected_tokens.len) {
        return error.ExpectedMoreTokens;
    }
}

test "short option without value" {
    try testTokenize(&.{"-f"}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = null,
        } },
    });
}

test "short option with value" {
    try testTokenize(&.{"-f=value"}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = "value",
        } },
    });

    try testTokenize(&.{"-f value"}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = "value",
        } },
    });
}

test "short option with empty value" {
    try testTokenize(&.{"-f="}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = null,
        } },
    });
}

test "short options chained" {
    try testTokenize(&.{"-fks"}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = null,
        } },
        Token{ .short_option = .{
            .name = 'k',
            .value = null,
        } },
        Token{ .short_option = .{
            .name = 's',
            .value = null,
        } },
    });
}

test "short options chained with value" {
    try testTokenize(&.{"-fks=foo"}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = "foo",
        } },
        Token{ .short_option = .{
            .name = 'k',
            .value = "foo",
        } },
        Token{ .short_option = .{
            .name = 's',
            .value = "foo",
        } },
    });

    try testTokenize(&.{"-fks foo"}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = "foo",
        } },
        Token{ .short_option = .{
            .name = 'k',
            .value = "foo",
        } },
        Token{ .short_option = .{
            .name = 's',
            .value = "foo",
        } },
    });
}

test "short options chained with empty value" {
    try testTokenize(&.{"-fks="}, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = null,
        } },
        Token{ .short_option = .{
            .name = 'k',
            .value = null,
        } },
        Token{ .short_option = .{
            .name = 's',
            .value = null,
        } },
    });
}

test "option without value" {
    try testTokenize(&.{"--option"}, &[_]Token{
        Token{ .option = .{
            .name = "option",
            .value = null,
        } },
    });
}

test "option with value" {
    try testTokenize(&.{"--option=bar"}, &[_]Token{
        Token{ .option = .{
            .name = "option",
            .value = "bar",
        } },
    });

    try testTokenize(&.{"--option bar"}, &[_]Token{
        Token{ .option = .{
            .name = "option",
            .value = "bar",
        } },
    });
}

test "option with empty value" {
    try testTokenize(&.{"--option="}, &[_]Token{
        Token{ .option = .{
            .name = "option",
            .value = null,
        } },
    });
}

test "single argument" {
    try testTokenize(&.{"filename.txt"}, &[_]Token{
        Token{ .arg = "filename.txt" },
    });
}

test "multiple arguments" {
    try testTokenize(&.{ "filename.txt", "build", "test stuff" }, &[_]Token{
        Token{ .arg = "filename.txt" },
        Token{ .arg = "build" },
        Token{ .arg = "test stuff" },
    });
}

test "arguments that look like options but aren't" {
    try testTokenize(&.{ "-", "--", "-=short_option", "--=option" }, &[_]Token{
        Token{ .arg = "-" },
        .separator,
        Token{ .arg = "-=short_option" },
        Token{ .arg = "--=option" },
    });
}

test "empty string arguments" {
    try testTokenize(&.{ "", "-f", "", "--option", "" }, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = null,
        } },
        Token{ .option = .{
            .name = "option",
            .value = null,
        } },
    });
}

test "options with special characters in thier values" {
    try testTokenize(&.{ "-f=hello world", "--option=key=value more" }, &[_]Token{
        Token{ .short_option = .{
            .name = 'f',
            .value = "hello world",
        } },
        Token{ .option = .{
            .name = "option",
            .value = "key=value more",
        } },
    });
}
