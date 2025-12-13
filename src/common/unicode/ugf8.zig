const std = @import("std");
const common = @import("../common.zig");

const UGF = @import("ugf.zig");

const UGF8 = @This();

pub const Buffer = struct {
    utf8: std.ArrayList(u8),
    units: std.ArrayList(Buffer.Unit),

    pub const empty = Buffer{
        .utf8 = .empty,
        .units = .empty,
    };

    pub inline fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.units.deinit(allocator);
        self.utf8.deinit(allocator);
    }

    pub fn append(self: *Buffer, allocator: std.mem.Allocator, item: UGF8.Unit) error{OutOfMemory}!void {
        try self.utf8.appendSlice(allocator, item.data);
        const buf_unit = Buffer.Unit{
            .start = self.utf8.items.len - item.data.len,
            .end = self.utf8.items.len,

            .codepoints_count = item.codepoints_count,
            .dw = item.dw,
        };

        try self.units.append(allocator, buf_unit);
    }

    pub fn appendAssumeCapacity(self: *Buffer, item: UGF8.Unit) void {
        self.utf8.appendSliceAssumeCapacity(item.data);
        const buf_unit = Buffer.Unit{
            .start = self.utf8.items.len - item.data.len,
            .end = self.utf8.items.len,

            .codepoints_count = item.codepoints_count,
            .dw = item.dw,
        };

        self.units.appendAssumeCapacity(buf_unit);
    }

    pub fn appendSlice(self: *Buffer, allocator: std.mem.Allocator, slice: []const UGF8.Unit) error{OutOfMemory}!void {
        const utf8_len = blk: {
            var utf8_len: usize = 0;
            for (slice) |item| {
                utf8_len += item.data.len;
            }
            break :blk utf8_len;
        };
        try self.utf8.ensureUnusedCapacity(allocator, utf8_len);
        try self.units.ensureUnusedCapacity(allocator, slice.len);

        self.appendSliceAssumeCapacity(slice);
    }

    pub fn appendSliceAssumeCapacity(self: *Buffer, slice: []const UGF8.Unit) void {
        for (slice) |item| {
            self.appendAssumeCapacity(item);
        }
    }

    pub fn pop(self: *Buffer) void {
        const unit = self.units.pop() orelse return;
        self.utf8.items.len -= unit.len();
    }

    pub fn popOwned(self: *Buffer, allocator: std.mem.Allocator) error{OutOfMemory}!?UGF8.Unit {
        const unit = self.units.pop() orelse return null;

        const owned = try unit.toOwnedUGF8(self, allocator);
        self.utf8.items.len -= owned.data.len;

        return owned;
    }

    pub fn asUTF8Slice(self: *const Buffer) []const u8 {
        return self.utf8.items;
    }
    
    pub fn asUGF8Slice(self: *const Buffer, allocator: std.mem.Allocator) error{OutOfMemory}![]const UGF8.Unit {
        var buf = try allocator.alloc(UGF8.Unit, self.units.items.len);
        errdefer allocator.free(buf);
        
        for (self.units.items, 0..) |unit, i| {
            buf[i] = unit.asUGF8(self);
        }

        return buf;
    }

    pub fn toUGF8Slice(self: *const Buffer, allocator: std.mem.Allocator) error{OutOfMemory}![]UGF8.Unit {
        var buf = try allocator.alloc(UGF8.Unit, self.units.items.len);
        errdefer allocator.free(buf);
        
        var i: usize = 0;
        errdefer if (i > 0) {
            for (buf[0..i]) |unit| {
                unit.deinit(allocator);
            }
        };
        
        for (self.units.items) |unit| {
            buf[i] = try unit.toOwnedUGF8(self, allocator);
            i += 1;
        }

        return buf;
    }

    pub const Unit = struct {
        start: usize,
        end: usize,

        codepoints_count: u13,
        dw: u7,

        pub inline fn len(self: *const Buffer.Unit) usize {
            return self.end - self.start;
        }

        pub inline fn data(self: *const Buffer.Unit, buffer: *const Buffer) []const u8 {
            return buffer.utf8.items[self.start..self.end];
        }

        pub inline fn asUGF8(self: *const Buffer.Unit, buffer: *const Buffer) UGF8.Unit {
            return UGF8.Unit{
                .data = buffer.utf8.items[self.start..self.end],
                .codepoints_count = self.codepoints_count,
                .dw = self.dw,
            };
        }

        pub fn toOwnedUGF8(self: *const Buffer.Unit, buffer: *const Buffer, allocator: std.mem.Allocator) error{OutOfMemory}!UGF8.Unit {
            const buf = try allocator.alloc(u8, self.end - self.start);
            @memcpy(buf, buffer.utf8.items[self.start..self.end]);

            return UGF8.Unit{
                .data = buf,
                .codepoints_count = self.codepoints_count,
                .dw = self.dw,
            };
        }
    };
};

pub const GapBufferConfig = struct {
    utf8: common.GapBufferConfig = .{},
    units: common.GapBufferConfig = .{},
};

pub fn GapBuffer(comptime config: GapBufferConfig) type {
    return struct {
        const Self = @This();

        utf8: common.GapBuffer(u8, config.utf8) = .empty,
        units: common.GapBuffer(Self.Unit, config.units) = .empty,

        pub const empty = Self{};

        pub inline fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.units.deinit(allocator);
            self.utf8.deinit(allocator);
        }

        pub inline fn firstHalf(self: *const Self) []const Self.Unit {
            return self.units.firstHalf();
        }

        pub inline fn secondHalf(self: *const Self) []const Self.Unit {
            return self.units.secondHalf();
        }

        pub fn insertUGF8AtCursor(self: *Self, allocator: std.mem.Allocator, unit: *const UGF8.Unit) error{OutOfMemory}!void {
            if (self.utf8.gap_size < unit.data.len) {
                @branchHint(.unlikely);
                try self.utf8.grow(allocator, unit.data.len);
            }

            if (self.units.gap_size < 1) {
                @branchHint(.unlikely);
                try self.units.grow(allocator, 1);
            }

            return insertUGF8AtCursorAssumeCapacity(self, unit);
        }

        pub fn insertUGF8AtCursorAssumeCapacity(self: *Self, unit: *const UGF8.Unit) void {
            self.utf8.insertSliceAtCursorAssumeCapacity(unit.data);

            const ugf8_unit = Self.Unit{
                .start = self.utf8.cur_idx - unit.data.len,
                .len = unit.data.len,
                .codepoints_count = unit.codepoints_count,
                .dw = unit.dw,
            };

            self.units.insertAtCursorAssumeCapacity(ugf8_unit);
        }

        pub fn insertUGF8SliceAtCursor(self: *Self, allocator: std.mem.Allocator, slice: []const UGF8.Unit) error{OutOfMemory}!void {
            var utf8_len: usize = 0;
            for (slice) |unit| {
                utf8_len += unit.data.len;
            }

            if (self.utf8.gap_size < utf8_len) {
                @branchHint(.unlikely);
                try self.utf8.grow(allocator, utf8_len);
            }

            if (self.units.gap_size < slice.len) {
                @branchHint(.unlikely);
                try self.units.grow(allocator, slice.len);
            }

            self.insertUGF8SliceAtCursorAssumeCapacity(slice);
        }

        pub fn insertUGF8SliceAtCursorAssumeCapacity(self: *Self, slice: []const UGF8.Unit) void {
            for (slice) |unit| {
                self.utf8.insertSliceAtCursorAssumeCapacity(unit.data);

                const buf_unit = Self.Unit{
                    .start = self.utf8.cur_idx - unit.data.len,
                    .len = unit.data.len,
                    .codepoints_count = unit.codepoints_count,
                    .dw = unit.dw,
                };

                self.units.insertAtCursorAssumeCapacity(buf_unit);
            }
        }

        pub fn insertUGFAtCursor(self: *Self, allocator: std.mem.Allocator, unit: *const UGF.Unit) error{ OutOfMemory, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
            var utf8_len: usize = 0;
            for (unit.slice()) |cp| {
                utf8_len += try std.unicode.utf8CodepointSequenceLength(cp);
            }

            if (self.utf8.gap_size < utf8_len) {
                @branchHint(.unlikely);
                try self.utf8.grow(allocator, utf8_len);
            }

            if (self.units.gap_size < 1) {
                @branchHint(.unlikely);
                try self.units.grow(allocator, 1);
            }

            return insertUGFAtCursorAssumeCapacity(self, unit);
        }

        pub inline fn insertUGFAtCursorAssumeCapacity(self: *Self, unit: *const UGF.Unit) error{ Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
            var utf8_len: usize = 0;
            for (unit.slice()) |cp| {
                utf8_len += try std.unicode.utf8CodepointSequenceLength(cp);

                var buf: [4]u8 = undefined;
                const cp_utf8_len = try std.unicode.utf8Encode(cp, &buf);

                self.utf8.insertSliceAtCursorAssumeCapacity(buf[0..cp_utf8_len]);
            }

            const buf_unit = Self.Unit{
                .start = self.utf8.cur_idx - utf8_len,
                .len = utf8_len,
                .codepoints_count = unit.len(),
                .dw = unit.dw,
            };

            self.units.insertAtCursorAssumeCapacity(buf_unit);
        }

        pub fn insertUGFSliceAtCursor(self: *Self, allocator: std.mem.Allocator, slice: []const UGF.Unit) error{ OutOfMemory, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
            var utf8_len: usize = 0;
            for (slice) |unit| {
                for (unit.slice()) |cp| {
                    utf8_len += try std.unicode.utf8CodepointSequenceLength(cp);
                }
            }

            if (self.utf8.gap_size < utf8_len) {
                @branchHint(.unlikely);
                try self.utf8.grow(allocator, utf8_len);
            }

            if (self.units.gap_size < slice.len) {
                @branchHint(.unlikely);
                try self.units.grow(allocator, slice.len);
            }

            return @call(.always_inline, insertUGFSliceAtCursorAssumeCapacity, .{ self, slice });
        }

        pub fn insertUGFSliceAtCursorAssumeCapacity(self: *Self, slice: []const UGF.Unit) error{ Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
            for (slice) |unit| {
                //TODO: optimize
                try self.insertUGFAtCursorAssumeCapacity(&unit);
            }
        }

        pub fn moveGapLeft(self: *Self, n: usize) error{UnableToMoveGap}![]const Self.Unit {
            const moved_units = try self.units.moveGapLeft(n);

            var utf8_len: usize = 0;
            for (moved_units) |*unit| {
                utf8_len += unit.len;
                unit.start += self.utf8.gap_size;
            }

            _ = self.utf8.moveGapLeft(utf8_len) catch unreachable;

            return moved_units;
        }

        pub fn moveGapRight(self: *Self, n: usize) error{UnableToMoveGap}![]const Self.Unit {
            const moved_units = try self.units.moveGapRight(n);

            var utf8_len: usize = 0;
            for (moved_units) |*unit| {
                utf8_len += unit.len;
                unit.start -= self.utf8.gap_size;
            }

            _ = self.utf8.moveGapRight(utf8_len) catch unreachable;

            return moved_units;
        }

        pub fn growGapLeft(self: *Self, n: usize) bool {
            if (!self.units.canGrowGapLeft(n)) {
                @branchHint(.cold);
                return false;
            }

            const removed_units: []const Self.Unit = self.units.firstHalf()[self.units.firstHalf().len - n .. self.units.firstHalf().len];

            var utf8_len: usize = 0;
            for (removed_units) |unit| {
                utf8_len += unit.len;
            }

            const grown_utf8 = self.utf8.growGapLeft(utf8_len);
            std.debug.assert(grown_utf8);

            const grown_units = self.units.growGapLeft(n);
            std.debug.assert(grown_units);

            return true;
        }

        pub fn growGapRight(self: *Self, n: usize) bool {
            if (!self.units.canGrowGapRight(n)) {
                @branchHint(.cold);
                return false;
            }

            const removed_units: []const Self.Unit = self.units.secondHalf()[0..n];

            var utf8_len: usize = 0;
            for (removed_units) |unit| {
                utf8_len += unit.len;
            }

            const grown_utf8 = self.utf8.growGapRight(utf8_len);
            std.debug.assert(grown_utf8);

            const grown_units = self.units.growGapRight(n);
            std.debug.assert(grown_units);

            return true;
        }

        pub inline fn clearAndFree(self: *Self, allocator: std.mem.Allocator) void {
            self.utf8.clearAndFree(allocator);
            self.units.clearAndFree(allocator);
        }

        pub inline fn clearRetainingCapacity(self: *Self) void {
            self.utf8.clearRetainingCapacity();
            self.units.clearRetainingCapacity();
        }

        pub inline fn len(self: *const Self) usize {
            return self.units.len();
        }

        pub fn toBuffer(self: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}!Buffer {
            var buf: Buffer = .empty;

            try buf.utf8.ensureUnusedCapacity(allocator, self.utf8.len());
            try buf.units.ensureUnusedCapacity(allocator, self.units.len());

            for (self.firstHalf()) |unit| {
                buf.appendAssumeCapacity(unit.toUnit(self));
            }
            for (self.secondHalf()) |unit| {
                buf.appendAssumeCapacity(unit.toUnit(self));
            }

            return buf;
        }

        pub const Unit = struct {
            start: usize,
            len: usize,

            codepoints_count: u13,
            dw: u7,

            pub inline fn data(self: *const Self.Unit, buffer: *const Self) []const u8 {
                return buffer.utf8.buf[self.start .. self.start + self.len];
            }

            pub inline fn toUnit(self: *const Self.Unit, buffer: *const Self) UGF8.Unit {
                return UGF8.Unit{
                    .data = buffer.utf8.buf[self.start .. self.start + self.len],
                    .codepoints_count = self.codepoints_count,
                    .dw = self.dw,
                };
            }

            pub fn toOwnedUnit(self: *const Self.Unit, buffer: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}!UGF8.Unit {
                const buf = try allocator.alloc(u8, self.end - self.start);
                @memcpy(buf, buffer.utf8.buf[self.start..self.end]);

                return UGF8.Unit{
                    .data = buf,
                    .codepoints_count = self.codepoints_count,
                    .dw = self.dw,
                };
            }
        };
    };
}

pub const Unit = struct {
    data: []const u8,
    codepoints_count: u13,
    dw: u7,

    pub inline fn init(alloc: std.mem.Allocator, slice: []const u8, codepoints_count: u13, dw: u7) error{OutOfMemory}!Unit {
        return initBuf(try alloc.dupe(u8, slice), codepoints_count, dw);
    }

    pub inline fn initBuf(slice: []const u8, codepoints_count: u13, dw: u7) Unit {
        return Unit{
            .data = slice,
            .codepoints_count = codepoints_count,
            .dw = dw,
        };
    }

    pub fn initCodepoints(alloc: std.mem.Allocator, codepoints: []const u21, dw: u7) error{ OutOfMemory, NotEnoughCodepoints, TooManyCodepoints, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!Unit {
        if (codepoints.len == 0) {
            return error.NotEnoughCodepoints;
        }
        if (codepoints.len > std.math.maxInt(u13) + 1) {
            return error.TooManyCodepoints;
        }

        const utf8_len = blk: {
            var utf8_len: usize = 0;
            for (codepoints) |cp| {
                utf8_len += try std.unicode.utf8CodepointSequenceLength(cp);
            }
            break :blk utf8_len;
        };

        const utf8_buf = try alloc.alloc(u8, utf8_len);
        var i: usize = 0;
        for (codepoints) |cp| {
            i += try std.unicode.utf8Encode(cp, utf8_buf[i..]);
        }

        return Unit{
            .data = utf8_buf,
            .codepoints_count = @intCast(codepoints.len - 1),
            .dw = dw,
        };
    }

    pub inline fn deinit(self: *const Unit, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
    }

    pub inline fn len(self: *const Unit) usize {
        return self.codepoints_count + 1;
    }

    pub inline fn match(self: *const Unit, data: []const u8) bool {
        return std.mem.eql(u8, self.data, data);
    }

    pub inline fn matchChr(self: *const Unit, chr: u8) bool {
        if (self.data.len != 1) {
            return false;
        }
        return self.data[0] == chr;
    }
};

pub const Encoder = struct {
    graphemes: common.Unicode.Graphemes,
    dw: common.Unicode.DisplayWidth,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Encoder {
        const graphemes = try common.Unicode.Graphemes.init(allocator);

        return Encoder{
            .graphemes = graphemes,
            .dw = try .initWithGraphemes(allocator, graphemes),
        };
    }

    pub fn deinit(self: *Encoder, allocator: std.mem.Allocator) void {
        self.graphemes.deinit(allocator);
        self.dw.deinit(allocator);
    }
    
    
};
