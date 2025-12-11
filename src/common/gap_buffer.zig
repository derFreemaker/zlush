const std = @import("std");

const common = @import("common.zig");

pub const GapBufferConfig = struct {
    grow: common.GrowStrategie = .{ .fixed = 128 },
};

pub fn GapBuffer(comptime T: type, comptime config: GapBufferConfig) type {
    return struct {
        const Self = @This();

        buf: []T,
        cur_idx: usize,
        gap_size: usize,

        pub const empty = Self{
            .buf = &.{},
            .cur_idx = 0,
            .gap_size = 0,
        };

        pub inline fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }

        pub inline fn firstHalf(self: *const Self) []const T {
            return self.buf[0..self.cur_idx];
        }

        pub inline fn firstHalfMut(self: *Self) []T {
            return self.buf[0..self.cur_idx];
        }

        pub inline fn secondHalf(self: *const Self) []const T {
            return self.buf[self.cur_idx + self.gap_size ..];
        }

        pub inline fn secondHalfMut(self: *Self) []T {
            return self.buf[self.cur_idx + self.gap_size ..];
        }

        inline fn gap(self: *Self) []T {
            return self.buf[self.cur_idx .. self.cur_idx + self.gap_size];
        }

        pub fn grow(self: *Self, allocator: std.mem.Allocator, n: usize) std.mem.Allocator.Error!void {
            const new_size = config.grow.calculate(self.buf.len, n);
            const new_buf = try allocator.alloc(T, new_size);

            @memcpy(new_buf[0..self.cur_idx], self.firstHalf());
            const second_half = self.secondHalf();
            @memcpy(new_buf[new_size - second_half.len ..], second_half);

            allocator.free(self.buf);
            self.buf = new_buf;
            self.gap_size = new_size - second_half.len - self.cur_idx;
        }

        pub fn insertAtCursor(self: *Self, allocator: std.mem.Allocator, item: T) std.mem.Allocator.Error!void {
            if (self.gap_size < 1) {
                @branchHint(.unlikely);
                try self.grow(allocator, 1);
            }

            insertAtCursorAssumeCapacity(self, item);
        }

        pub inline fn insertAtCursorAssumeCapacity(self: *Self, item: T) void {
            self.gap()[0] = item;
            self.cur_idx += 1;
            self.gap_size -= 1;
        }

        pub fn insertSliceAtCursor(self: *Self, allocator: std.mem.Allocator, slice: []const T) std.mem.Allocator.Error!void {
            if (self.gap_size < slice.len) {
                @branchHint(.unlikely);
                try self.grow(allocator, slice.len);
            }

            @call(.always_inline, insertSliceAtCursorAssumeCapacity, .{ self, slice });
        }

        pub fn insertSliceAtCursorAssumeCapacity(self: *Self, slice: []const T) void {
            @memcpy(self.gap()[0..slice.len], slice);
            self.cur_idx += slice.len;
            self.gap_size -= slice.len;
        }

        pub fn moveGapLeft(self: *Self, n: usize) error{UnableToMoveGap}![]T {
            if (n > self.cur_idx) {
                @branchHint(.cold);
                return error.UnableToMoveGap;
            }
            const new_idx = self.cur_idx - n;

            const src = self.buf[new_idx..self.cur_idx];
            const dst = self.buf[new_idx + self.gap_size .. new_idx + self.gap_size + src.len];
            @memmove(dst, src);

            self.cur_idx = new_idx;
            return dst;
        }

        pub fn moveGapRight(self: *Self, n: usize) error{UnableToMoveGap}![]T {
            if (n > self.secondHalf().len) {
                @branchHint(.cold);
                return error.UnableToMoveGap;
            }
            const new_idx = self.cur_idx + n;

            const src = self.buf[self.cur_idx + self.gap_size .. new_idx + self.gap_size];
            const dst = self.buf[self.cur_idx .. self.cur_idx + src.len];
            @memmove(dst, src);

            self.cur_idx = new_idx;
            return dst;
        }

        pub inline fn canGrowGapLeft(self: *const Self, n: usize) bool {
            return self.cur_idx >= n;
        } 
        
        pub fn growGapLeft(self: *Self, n: usize) bool {
            if (!self.canGrowGapLeft(n)) {
                @branchHint(.cold);
                return false;
            }

            self.gap_size += n;
            self.cur_idx -= n;
            return true;
        }
        
        pub inline fn canGrowGapRight(self: *const Self, n: usize) bool {
            return self.secondHalf().len >= n; 
        }

        pub fn growGapRight(self: *Self, n: usize) bool {
            if (!self.canGrowGapRight(n)) {
                @branchHint(.cold);
                return false;
            }

            self.gap_size += n;
            return true;
        }

        pub inline fn clearAndFree(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
            self.* = .init;
        }

        pub inline fn clearRetainingCapacity(self: *Self) void {
            self.cur_idx = 0;
            self.gap_size = self.buf.len;
        }

        pub fn toOwnedSlice(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]T {
            const first_half = self.firstHalf();
            const second_half = self.secondHalf();

            const buf = try allocator.alloc(T, first_half.len + second_half.len);
            @memcpy(buf[0..first_half.len], first_half);
            @memcpy(buf[first_half.len..], second_half);

            self.clearAndFree(allocator);
            return buf;
        }

        pub inline fn len(self: *const Self) usize {
            return self.buf.len - self.gap_size;
        }
    };
}

test "GapBuffer" {
    const allocator = std.testing.allocator;

    var gap_buf: GapBuffer(u8, .{}) = .empty;
    defer gap_buf.deinit(allocator);

    try gap_buf.insertSliceAtCursor(allocator, "abc");
    try std.testing.expectEqualStrings("abc", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("", gap_buf.secondHalf());
    
    try std.testing.expect((gap_buf.moveGapLeft(1) catch &.{}).len != 0);
    try std.testing.expectEqualStrings("ab", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("c", gap_buf.secondHalf());

    try gap_buf.insertSliceAtCursor(allocator, " ");
    try std.testing.expectEqualStrings("ab ", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("c", gap_buf.secondHalf());

    try std.testing.expect(gap_buf.growGapLeft(1));
    try std.testing.expectEqualStrings("ab", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("c", gap_buf.secondHalf());
    try std.testing.expectEqual(2, gap_buf.cur_idx);

    try std.testing.expect(gap_buf.growGapRight(1));
    try std.testing.expectEqualStrings("ab", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("", gap_buf.secondHalf());
    try std.testing.expectEqual(2, gap_buf.cur_idx);
}
