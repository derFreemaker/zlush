const std = @import("std");
const common = @import("../common.zig");

const UGF = @import("ugf.zig");

const UGF8 = @This();

pub const Buffer = struct {
    data: std.ArrayList(u8),
    units: std.ArrayList(Buffer.Unit),

    pub const empty = Buffer{
        .data = .empty,
        .units = .empty,
    };

    pub inline fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.units.deinit(allocator);
        self.data.deinit(allocator);
    }

    pub fn append(self: *Buffer, allocator: std.mem.Allocator, item: UGF8.Unit) error{OutOfMemory}!void {
        const buf_unit = Buffer.Unit{
            .start = self.data.items.len,
            .len = item.data.len,

            .codepoints_count = item.codepoints_count,
            .dw = item.dw,
        };
        try self.data.appendSlice(allocator, item.data);

        try self.units.append(allocator, buf_unit);
    }

    pub fn appendAssumeCapacity(self: *Buffer, item: UGF8.Unit) void {
        const buf_unit = Buffer.Unit{
            .start = self.data.items.len,
            .len = item.data.len,

            .codepoints_count = item.codepoints_count,
            .dw = item.dw,
        };
        self.data.appendSliceAssumeCapacity(item.data);

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
        try self.data.ensureUnusedCapacity(allocator, utf8_len);
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
        self.data.items.len -= unit.len;
    }

    pub fn popOwned(self: *Buffer, allocator: std.mem.Allocator) error{OutOfMemory}!?UGF8.Unit {
        const unit = self.units.pop() orelse return null;

        const owned = try unit.toOwnedUGF8(self, allocator);
        self.data.items.len -= owned.data.len;

        return owned;
    }

    pub fn asBufferView(self: *const Buffer) BufferView {
        return BufferView{
            .data = self.data.items,
            .units = self.units.items,
        };
    }

    /// Returns `UnusedCapacity` if the memory inside the buffer is not used to it's fullest,
    /// leading to lose of accessibility to the memory if called.
    pub fn toBufferView(self: *const Buffer) error{UnusedCapacity}!BufferView {
        if (self.data.capacity > self.data.items.len or
            self.units.capacity > self.units.items.len)
        {
            return error.UnusedCapacity;
        }

        return self.asBufferView();
    }

    pub fn cloneToBufferView(self: *const Buffer, allocator: std.mem.Allocator) error{OutOfMemory}!BufferView {
        const data = try allocator.dupe(u8, self.data.items);
        errdefer allocator.free(data);

        const units = try allocator.dupe(Buffer.Unit, self.units.items);
        errdefer allocator.free(units);

        return BufferView{
            .data = data,
            .units = units,
        };
    }

    pub fn asUTF8Slice(self: *const Buffer) []const u8 {
        return self.data.items;
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
        len: usize,

        codepoints_count: u13,
        dw: u7,

        pub inline fn data(self: *const Buffer.Unit, buffer: *const Buffer) []const u8 {
            return buffer.data.items[self.start .. self.start + self.len];
        }

        pub inline fn asUGF8(self: *const Buffer.Unit, buffer: *const Buffer) UGF8.Unit {
            return UGF8.Unit{
                .data = self.data(buffer),
                .codepoints_count = self.codepoints_count,
                .dw = self.dw,
            };
        }

        pub fn toOwnedUGF8(self: *const Buffer.Unit, buffer: *const Buffer, allocator: std.mem.Allocator) error{OutOfMemory}!UGF8.Unit {
            const buf = try allocator.alloc(u8, self.len);
            @memcpy(buf, self.data(buffer));

            return UGF8.Unit{
                .data = buf,
                .codepoints_count = self.codepoints_count,
                .dw = self.dw,
            };
        }
    };
};

pub const BufferView = struct {
    data: []const u8,
    units: []const Buffer.Unit,

    /// Only call this if you know the view owns the memory.
    pub fn deinit(self: *BufferView, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.units);
    }

    pub fn asUTF8Slice(self: *const BufferView) []const u8 {
        return self.data;
    }
};

pub const GapBufferConfig = struct {
    utf8: common.GapBufferConfig = .{},
    units: common.GapBufferConfig = .{},
};

pub fn GapBuffer(comptime config: GapBufferConfig) type {
    return struct {
        const Self = @This();

        data: common.GapBuffer(u8, config.utf8) = .empty,
        units: common.GapBuffer(Self.Unit, config.units) = .empty,

        pub const empty = Self{};

        pub inline fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.units.deinit(allocator);
            self.data.deinit(allocator);
        }

        pub inline fn firstHalf(self: *const Self) []const Self.Unit {
            return self.units.firstHalf();
        }

        pub inline fn secondHalf(self: *const Self) []const Self.Unit {
            return self.units.secondHalf();
        }

        pub fn insertBufferViewAtCursor(self: *Self, allocator: std.mem.Allocator, view: BufferView) error{OutOfMemory}!void {
            if (self.data.gap_size < view.data.len) {
                try self.data.grow(allocator, view.data.len);
            }

            if (self.units.gap_size < 1) {
                try self.units.grow(allocator, view.units.len);
            }

            const data_cur_idx = self.data.cur_idx;
            self.data.insertSliceAtCursorAssumeCapacity(view.data);
            for (view.units) |unit| {
                const buf_unit = Self.Unit{
                    .start = data_cur_idx + unit.start,
                    .len = unit.len,
                    .codepoints_count = unit.codepoints_count,
                    .dw = unit.dw,
                };

                self.units.insertAtCursorAssumeCapacity(buf_unit);
            }
        }

        pub fn insertUGF8AtCursor(self: *Self, allocator: std.mem.Allocator, unit: *const UGF8.Unit) error{OutOfMemory}!void {
            if (self.data.gap_size < unit.data.len) {
                @branchHint(.unlikely);
                try self.data.grow(allocator, unit.data.len);
            }

            if (self.units.gap_size < 1) {
                @branchHint(.unlikely);
                try self.units.grow(allocator, 1);
            }

            return insertUGF8AtCursorAssumeCapacity(self, unit);
        }

        pub fn insertUGF8AtCursorAssumeCapacity(self: *Self, unit: *const UGF8.Unit) void {
            self.data.insertSliceAtCursorAssumeCapacity(unit.data);

            const buf_unit = Self.Unit{
                .start = self.data.cur_idx - unit.data.len,
                .len = unit.data.len,
                .codepoints_count = unit.codepoints_count,
                .dw = unit.dw,
            };

            self.units.insertAtCursorAssumeCapacity(buf_unit);
        }

        pub fn insertUGF8SliceAtCursor(self: *Self, allocator: std.mem.Allocator, slice: []const UGF8.Unit) error{OutOfMemory}!void {
            var utf8_len: usize = 0;
            for (slice) |unit| {
                utf8_len += unit.data.len;
            }

            if (self.data.gap_size < utf8_len) {
                try self.data.grow(allocator, utf8_len);
            }

            if (self.units.gap_size < slice.len) {
                try self.units.grow(allocator, slice.len);
            }

            self.insertUGF8SliceAtCursorAssumeCapacity(slice);
        }

        pub fn insertUGF8SliceAtCursorAssumeCapacity(self: *Self, slice: []const UGF8.Unit) void {
            for (slice) |unit| {
                self.data.insertSliceAtCursorAssumeCapacity(unit.data);

                const buf_unit = Self.Unit{
                    .start = self.data.cur_idx - unit.data.len,
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

            if (self.data.gap_size < utf8_len) {
                @branchHint(.unlikely);
                try self.data.grow(allocator, utf8_len);
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

                self.data.insertSliceAtCursorAssumeCapacity(buf[0..cp_utf8_len]);
            }

            const buf_unit = Self.Unit{
                .start = self.data.cur_idx - utf8_len,
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

            if (self.data.gap_size < utf8_len) {
                try self.data.grow(allocator, utf8_len);
            }

            if (self.units.gap_size < slice.len) {
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
                unit.start += self.data.gap_size;
            }

            _ = self.data.moveGapLeft(utf8_len) catch unreachable;

            return moved_units;
        }

        pub fn moveGapRight(self: *Self, n: usize) error{UnableToMoveGap}![]const Self.Unit {
            const moved_units = try self.units.moveGapRight(n);

            var utf8_len: usize = 0;
            for (moved_units) |*unit| {
                utf8_len += unit.len;
                unit.start -= self.data.gap_size;
            }

            _ = self.data.moveGapRight(utf8_len) catch unreachable;

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

            const grown_utf8 = self.data.growGapLeft(utf8_len);
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

            const grown_utf8 = self.data.growGapRight(utf8_len);
            std.debug.assert(grown_utf8);

            const grown_units = self.units.growGapRight(n);
            std.debug.assert(grown_units);

            return true;
        }

        pub inline fn clearAndFree(self: *Self, allocator: std.mem.Allocator) void {
            self.data.clearAndFree(allocator);
            self.units.clearAndFree(allocator);
        }

        pub inline fn clearRetainingCapacity(self: *Self) void {
            self.data.clearRetainingCapacity();
            self.units.clearRetainingCapacity();
        }

        pub inline fn len(self: *const Self) usize {
            return self.units.len();
        }

        pub fn cloneToBuffer(self: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}!Buffer {
            var buf: Buffer = .empty;

            try buf.data.ensureTotalCapacityPrecise(allocator, self.data.len());
            try buf.units.ensureTotalCapacityPrecise(allocator, self.units.len());

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
                return buffer.data.buf[self.start .. self.start + self.len];
            }

            pub inline fn toUnit(self: *const Self.Unit, buffer: *const Self) UGF8.Unit {
                return UGF8.Unit{
                    .data = buffer.data.buf[self.start .. self.start + self.len],
                    .codepoints_count = self.codepoints_count,
                    .dw = self.dw,
                };
            }

            pub fn toOwnedUnit(self: *const Self.Unit, buffer: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}!UGF8.Unit {
                const buf = try allocator.alloc(u8, self.end - self.start);
                @memcpy(buf, buffer.data.buf[self.start..self.end]);

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

    pub const empty = Unit{
        .data = &.{},
        .codepoints_count = 0,
        .dw = 0,
    };

    pub inline fn init(allocator: std.mem.Allocator, slice: []const u8, codepoints_count: u13, dw: u7) error{OutOfMemory}!Unit {
        return initBuf(try allocator.dupe(u8, slice), codepoints_count, dw);
    }

    pub inline fn initBuf(slice: []const u8, codepoints_count: u13, dw: u7) Unit {
        return Unit{
            .data = slice,
            .codepoints_count = codepoints_count,
            .dw = dw,
        };
    }

    pub fn initCodepoints(allocator: std.mem.Allocator, codepoints: []const u21, dw: u7) error{ OutOfMemory, NotEnoughCodepoints, TooManyCodepoints, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!Unit {
        if (codepoints.len == 0) {
            return error.NotEnoughCodepoints;
        }
        if (codepoints.len > std.math.maxInt(u13)) {
            return error.TooManyCodepoints;
        }

        const utf8_len = blk: {
            var utf8_len: usize = 0;
            for (codepoints) |cp| {
                utf8_len += try std.unicode.utf8CodepointSequenceLength(cp);
            }
            break :blk utf8_len;
        };

        const utf8_buf = try allocator.alloc(u8, utf8_len);
        var i: usize = 0;
        for (codepoints) |cp| {
            i += try std.unicode.utf8Encode(cp, utf8_buf[i..]);
        }

        return Unit{
            .data = utf8_buf,
            .codepoints_count = codepoints.len,
            .dw = dw,
        };
    }

    pub inline fn deinit(self: *const Unit, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub inline fn clone(self: *const Unit, allocator: std.mem.Allocator) Unit {
        return init(allocator, self.data, self.codepoints_count, self.dw);
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

    pub fn initWith(graphemes: common.Unicode.Graphemes, dw: common.Unicode.DisplayWidth) Encoder {
        return Encoder{
            .graphemes = graphemes,
            .dw = dw,
        };
    }

    pub fn deinit(self: *Encoder, allocator: std.mem.Allocator) void {
        self.graphemes.deinit(allocator);
        self.dw.deinit(allocator);
    }

    const EncodeError = error{
        OutOfMemory,
        Utf8InvalidStartByte,
        TruncatedInput,
        Utf8ExpectedContinuation,
        Utf8OverlongEncoding,
        Utf8EncodesSurrogateHalf,
        Utf8CodepointTooLarge,
    };

    pub fn encodeToBuffer(self: *const Encoder, allocator: std.mem.Allocator, slice: []const u8) EncodeError!Buffer {
        var buf: Buffer = .empty;
        errdefer buf.deinit(allocator);

        try buf.data.ensureTotalCapacityPrecise(allocator, slice.len);
        try buf.units.ensureTotalCapacity(allocator, slice.len);

        var iter = self.graphemes.iterator(slice);
        while (iter.next()) |grapheme| {
            const grapheme_slice = grapheme.bytes(slice);
            const dw: u7 = @intCast(self.dw.strWidth(grapheme_slice));
            const codepoints_count: u13 = @intCast(try std.unicode.utf8CountCodepoints(grapheme_slice));

            const unit = common.Unicode.UGF8.Unit.initBuf(grapheme_slice, codepoints_count, dw);
            buf.appendAssumeCapacity(unit);
        }

        return buf;
    }

    pub fn encodeToBufferView(self: *const Encoder, allocator: std.mem.Allocator, slice: []const u8) EncodeError!BufferView {
        var buf: Buffer = .empty;
        errdefer buf.deinit(allocator);

        try buf.data.ensureTotalCapacityPrecise(allocator, slice.len);

        var count: usize = 0;
        var iter = self.graphemes.iterator(slice);
        while (iter.next()) |_| {
            count += 1;
        }

        try buf.units.ensureTotalCapacityPrecise(allocator, count);

        iter = self.graphemes.iterator(slice);
        while (iter.next()) |grapheme| {
            const grapheme_slice = grapheme.bytes(slice);
            const dw: u7 = @intCast(self.dw.strWidth(grapheme_slice));
            const codepoints_count: u13 = @intCast(try std.unicode.utf8CountCodepoints(grapheme_slice));

            const unit = common.Unicode.UGF8.Unit.initBuf(grapheme_slice, codepoints_count, dw);
            buf.appendAssumeCapacity(unit);
        }

        return buf.toBufferView() catch unreachable;
    }
};
