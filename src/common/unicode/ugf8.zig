const std = @import("std");
const common = @import("../common.zig");

const UGF = @import("ugf.zig");

pub const GapBufferConfig = struct {
    utf8: common.GapBufferConfig = .{},
    units: common.GapBufferConfig = .{},
};

pub fn GapBuffer(comptime config: GapBufferConfig) type {
    return struct {
        const Self = @This();

        utf8: common.GapBuffer(u8, config.utf8) = .init,
        units: common.GapBuffer(Unit, config.units) = .init,

        pub const init = Self{};

        pub inline fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.units.deinit(allocator);
            self.utf8.deinit(allocator);
        }

        pub inline fn firstHalf(self: *const Self) []const Unit {
            return self.units.firstHalf();
        }

        pub inline fn secondHalf(self: *const Self) []const Unit {
            return self.units.secondHalf();
        }

        pub fn insertAtCursor(self: *Self, allocator: std.mem.Allocator, unit: *const UGF.Unit) error{ OutOfMemory, Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
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

            return insertAtCursorAssumeCapacity(self, unit);
        }

        pub inline fn insertAtCursorAssumeCapacity(self: *Self, unit: *const UGF.Unit) error{ Utf8CannotEncodeSurrogateHalf, CodepointTooLarge }!void {
            var utf8_len: usize = 0;
            for (unit.slice()) |cp| {
                utf8_len += try std.unicode.utf8CodepointSequenceLength(cp);
            }

            for (unit.slice()) |cp| {
                var buf: [4]u8 = undefined;
                const cp_utf8_len = try std.unicode.utf8Encode(cp, &buf);
                
                self.utf8.insertSliceAtCursorAssumeCapacity(buf[0..cp_utf8_len]);
            }

            const ugf8_unit = Unit{
                .data = self.utf8.buf[self.utf8.cur_idx - utf8_len .. self.utf8.cur_idx],
                .dw = unit.dw,
            };

            self.units.insertAtCursorAssumeCapacity(ugf8_unit);
        }

        pub fn insertSliceAtCursor(self: *Self, allocator: std.mem.Allocator, slice: []const UGF.Unit) std.mem.Allocator.Error!void {
            var utf8_len: usize = 0;
            for (slice) |unit| {
                for (unit.slice()) |cp| {
                    utf8_len += std.unicode.utf8CodepointSequenceLength(cp);
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

            @call(.always_inline, insertSliceAtCursorAssumeCapacity, .{ self, slice });
        }

        pub fn insertSliceAtCursorAssumeCapacity(self: *Self, slice: []const UGF.Unit) void {
            for (slice) |unit| {
                self.insertAtCursorAssumeCapacity(unit);
            }
        }

        pub fn moveGapLeft(self: *Self, n: usize) error{UnableToMoveGap}!void {
            const moved_units = try self.units.moveGapLeft(n);

            var utf8_len: usize = 0;
            for (moved_units) |*unit| {
                utf8_len += unit.data.len;
                var ptr = @intFromPtr(unit.data.ptr);
                ptr += self.units.gap_size;
                unit.data = @as([*]const u8, @ptrFromInt(ptr))[0..unit.data.len];
            }

            _ = self.utf8.moveGapLeft(utf8_len) catch unreachable;
        }

        pub fn moveGapRight(self: *Self, n: usize) error{UnableToMoveGap}!void {
            const moved_units = try self.units.moveGapRight(n);

            var utf8_len: usize = 0;
            for (moved_units) |*unit| {
                utf8_len += unit.data.len;
                var ptr = @intFromPtr(unit.data.ptr);
                ptr -= self.units.gap_size;
                unit.data = @as([*]const u8, @ptrFromInt(ptr))[0..unit.data.len];
            }
            _ = self.utf8.moveGapRight(utf8_len) catch unreachable;
        }

        pub fn growGapLeft(self: *Self, n: usize) bool {
            if (!self.units.canGrowGapLeft(n)) {
                @branchHint(.cold);
                return false;
            }

            const removed_units: []const Unit = self.units.firstHalf()[self.units.firstHalf().len - n .. self.units.firstHalf().len];
            
            var utf8_len: usize = 0;
            for (removed_units) |unit| {
                utf8_len += unit.data.len;
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

            const removed_units: []const Unit = self.units.secondHalf()[0..n];

            var utf8_len: usize = 0;
            for (removed_units) |unit| {
                utf8_len += unit.data.len;
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
    };
}

pub const Unit = struct {
    data: []const u8,
    dw: u7,
};
