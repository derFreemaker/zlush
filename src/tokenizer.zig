const std = @import("std");
const common = @import("common");
const UGF8 = common.Unicode.UGF8;

const Tokenizer = @This();

source: UGF8.Buffer,
cursor: usize,

pub fn init(source: UGF8.Buffer) Tokenizer {
    return Tokenizer{
        .source = source,
        .cursor = 0,
    };
}

pub fn next(self: *Tokenizer) ?[]const u8 {
    while (true) {
        const cur = self.peek(0) orelse return null;
        if (cur.codepoints_count == 0) {
            return null;
        }

        switch (cur.data(&self.source)[0]) {
            ' ' => {
                self.toss(1);
                continue;
            },

            '\"' => {
                var len: usize = 1;
                while (self.peek(len)) |unit| {
                    if (unit.toUnit(&self.source).matchChr('\\')) {
                        if (self.peek(len + 1)) |after| {
                            if (after.toUnit(&self.source).matchChr('\"')) {
                                len += 2;
                                continue;
                            }
                        }
                    }

                    if (unit.toUnit(&self.source).matchChr('\"')) {
                        break;
                    }

                    len += 1;
                }

                return self.sliceTo(len - 1);
            },

            '\'' => {
                var len: usize = 1;
                while (self.peek(len)) |unit| {
                    if (unit.toUnit(&self.source).matchChr('\\')) {
                        if (self.peek(len + 1)) |after| {
                            if (after.toUnit(&self.source).matchChr('\'')) {
                                len += 2;
                                continue;
                            }
                        }
                    }

                    if (unit.toUnit(&self.source).matchChr('\'')) {
                        break;
                    }

                    len += 1;
                }

                return self.sliceTo(len - 1);
            },

            else => {
                var len: usize = 1;
                while (self.peek(len)) |unit| {
                    if (unit.toUnit(&self.source).matchChr(' ')) {
                        break;
                    }
                    len += 1;
                }

                return self.sliceTo(len - 1);
            },
        }
    }
}

inline fn peek(self: *Tokenizer, n: usize) ?UGF8.Buffer.Item {
    if (self.cursor + n >= self.source.units.items.len) {
        return null;
    }

    return self.source.units.items[self.cursor + n];
}

inline fn toss(self: *Tokenizer, n: usize) void {
    self.cursor += @min(n, self.source.units.items.len - self.cursor);
}

inline fn sliceTo(self: *Tokenizer, n: usize) []const u8 {
    std.debug.assert(self.cursor + n <= self.source.units.items.len);

    const start = self.source.units.items[self.cursor].start;
    const end = self.source.units.items[self.cursor + n].end;

    defer self.toss(n + 1);
    return self.source.utf8.items[start..end];
}
