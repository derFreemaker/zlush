const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,

        pub inline fn getBytes(self: Loc, source: []const u8) []const u8 {
            return source[self.start..self.end];
        }
    };

    pub const Tag = enum {
        invalid,
        eof,

        identifier,
        number_literal,
        string_literal,

        comma,
        semicolon,
        colon,
        dot,
        minus,
        plus,
        asterisk,
        percent,
        ampersand,
        hash_sign,
        dollar_sign,
        slash,
        back_slash,
        tilde,
        caret,
        pipe,
        question_mark,

        l_angle_bracket,
        r_angle_bracket,
        l_paren,
        r_paren,
        l_bracket,
        r_bracket,
        l_brace,
        r_brace,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .eof,
                .identifier,
                .number_literal,
                .string_literal,
                => null,

                .comma => ",",
                .semicolon => ";",
                .colon => ":",
                .dot => ".",
                .minus => "-",
                .plus => "+",
                .asterisk => "*",
                .percent => "%",
                .ampersand => "&",
                .hash_sign => "#",
                .dollar_sign => "$",
                .slash => "/",
                .back_slash => "\\",
                .l_angle_bracket => "<",
                .r_angle_bracket => ">",
                .tilde => "~",
                .caret => "^",
                .pipe => "|",
                .question_mark => "?",

                .l_paren => "(",
                .r_paren => ")",
                .l_bracket => "[",
                .r_bracket => "]",
                .l_brace => "{",
                .r_brace => "}",
            };
        }
    };
};

const Tokenizer = @This();

buf: [:0]const u8,
index: usize = 0,
next_token: ?Token = null,

pub fn init(buf: [:0]const u8) Tokenizer {
    return Tokenizer{
        .buf = buf,
    };
}

pub fn dump(self: *Tokenizer, token: *const Token) void {
    std.debug.print("{s} '{s}'\n", .{
        @tagName(token.tag),
        token.loc.getBytes(self.buf),
    });
}

const State = enum {
    invalid,
    start,
    eof,

    identifier,
    number_literal,
    string_literal,
};

pub fn peek(self: *Tokenizer) Token {
    if (self.next_token) |token| {
        return token;
    }

    var token = Token{
        .tag = undefined,
        .loc = .{
            .start = self.index,
            .end = undefined,
        },
    };

    state: switch (State.start) {
        .invalid => {
            self.index += 1;
            switch (self.buf[self.index]) {
                0 => {
                    if (self.index == self.buf.len) {
                        token.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    }
                },
                ' ', '\t', '\n', '\r' => token.tag = .invalid,
                else => continue :state .invalid,
            }
        },

        .start => switch (self.buf[self.index]) {
            0 => {
                if (self.index == self.buf.len) {
                    continue :state .eof;
                }

                continue :state .invalid;
            },
            ' ', '\t', '\n', '\r' => {
                self.index += 1;
                token.loc.start = self.index;
                continue :state .start;
            },

            'a'...'z', 'A'...'Z', '_' => {
                token.tag = .identifier;
                continue :state .identifier;
            },
            '0'...'9' => {
                token.tag = .number_literal;
                continue :state .number_literal;
            },
            '"' => {
                token.tag = .string_literal;
                continue :state .string_literal;
            },

            ',' => {
                self.index += 1;
                token.tag = .comma;
            },
            ';' => {
                self.index += 1;
                token.tag = .semicolon;
            },
            ':' => {
                self.index += 1;
                token.tag = .colon;
            },
            '.' => {
                self.index += 1;
                token.tag = .dot;
            },
            '-' => {
                self.index += 1;
                token.tag = .minus;
            },
            '+' => {
                self.index += 1;
                token.tag = .plus;
            },
            '*' => {
                self.index += 1;
                token.tag = .asterisk;
            },
            '%' => {
                self.index += 1;
                token.tag = .percent;
            },
            '&' => {
                self.index += 1;
                token.tag = .ampersand;
            },
            '$' => {
                self.index += 1;
                token.tag = .dollar_sign;
            },
            '#' => {
                self.index += 1;
                token.tag = .hash_sign;
            },
            '/' => {
                self.index += 1;
                token.tag = .slash;
            },
            '\\' => {
                self.index += 1;
                token.tag = .back_slash;
            },
            '~' => {
                self.index += 1;
                token.tag = .tilde;
            },
            '^' => {
                self.index += 1;
                token.tag = .caret;
            },
            '|' => {
                self.index += 1;
                token.tag = .pipe;
            },
            '?' => {
                self.index += 1;
                token.tag = .question_mark;
            },

            '<' => {
                self.index += 1;
                token.tag = .l_angle_bracket;
            },
            '>' => {
                self.index += 1;
                token.tag = .r_angle_bracket;
            },
            '(' => {
                self.index += 1;
                token.tag = .l_paren;
            },
            ')' => {
                self.index += 1;
                token.tag = .r_paren;
            },
            '[' => {
                self.index += 1;
                token.tag = .l_bracket;
            },
            ']' => {
                self.index += 1;
                token.tag = .r_bracket;
            },
            '{' => {
                self.index += 1;
                token.tag = .l_brace;
            },
            '}' => {
                self.index += 1;
                token.tag = .r_brace;
            },

            else => continue :state .invalid,
        },

        .eof => {
            token.tag = .eof;
        },

        .identifier => {
            self.index += 1;
            switch (self.buf[self.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                else => {},
            }
        },

        .number_literal => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '0'...'9', 'a'...'z', 'A'...'Z' => continue :state .number_literal,
                else => {},
            }
        },

        .string_literal => {
            self.index += 1;
            switch (self.buf[self.index]) {
                '"' => {
                    self.index += 1;
                },
                '\\' => {
                    self.index += 1;
                    switch (self.buf[self.index]) {
                        0 => {},
                        else => {
                            self.index += 1;
                            continue :state .string_literal;
                        },
                    }
                },
                0 => {},
                else => continue :state .string_literal,
            }
        },
    }

    token.loc.end = self.index;
    self.next_token = token;
    return token;
}

pub fn toss(self: *Tokenizer) void {
    if (self.next_token != null) {
        self.next_token = null;
    } else {
        _ = self.next();
    }
}

pub fn next(self: *Tokenizer) Token {
    const token = self.peek();
    self.toss();
    return token;
}

fn testTokenize(source: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        // tokenizer.dump(&token);
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }

    // Last token should always be eof, even when the last token was invalid,
    // in which case the tokenizer is in an invalid state, which can only be
    // recovered by opinionated means outside the scope of this implementation.
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}

test "invalid" {
    try testTokenize("\x00test", &[_]Token.Tag{
        .invalid,
    });

    try testTokenize("\x00 test", &[_]Token.Tag{
        .invalid,
        .identifier,
    });
}

test "identifier" {
    try testTokenize("foo bar", &[_]Token.Tag{
        .identifier,
        .identifier,
    });
}

test "number_literal" {
    try testTokenize("123 83267 0xFF 0b10101 -19", &[_]Token.Tag{
        .number_literal,
        .number_literal,
        .number_literal,
        .number_literal,
        .minus,
        .number_literal,
    });
}

test "string_literal" {
    try testTokenize("\"asd\", \"asdklj\", \"\\\"foo\\\"\"", &[_]Token.Tag{
        .string_literal,
        .comma,
        .string_literal,
        .comma,
        .string_literal,
    });
}
