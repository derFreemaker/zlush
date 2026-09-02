const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Indexes = @import("index.zig");

pub const PageSize = enum(u4) {
    @"16" = 4, // 2^4
    @"32" = 5, // 2^5
    @"64" = 6, // 2^6
    @"128" = 7, // 2^7
    @"256" = 8, // 2^8
    @"512" = 9, // 2^9
    @"1024" = 10, // 2^10
    @"2048" = 11, // 2^11
    @"4096" = 12, // 2^12

    pub inline fn size(self: PageSize) usize {
        return @as(usize, 1) << @intFromEnum(self);
    }
};

pub fn SparseSet(comptime T: type, comptime IndexT: type, comptime page_size: PageSize) type {
    return struct {
        const Page = []?usize;

        const Self = @This();

        len: usize,
        dense: []T,

        inverse: []IndexT,
        spares: []?Page,

        pub const empty = Self{
            .len = 0,
            .dense = &.{},

            .inverse = &.{},
            .spares = &.{},
        };

        pub fn initCapacity(self: *Self, gpa: Allocator, capacity: usize) Allocator.Error!void {
            self.len = 0;

            self.dense = try gpa.alloc(T, capacity);
            errdefer gpa.free(self.dense);

            self.inverse = try gpa.alloc(IndexT, capacity);
            errdefer gpa.free(self.inverse);

            self.spares = &.{};
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.spares) |maybe_page| {
                const page = maybe_page orelse continue;
                gpa.free(page);
            }
            gpa.free(self.spares);
            gpa.free(self.inverse);

            gpa.free(self.dense);
        }

        pub fn get(self: *const Self, idx: IndexT) *T {
            const dense_idx = self.getDenseIdx(idx) orelse unreachable;
            return &self.dense[dense_idx];
        }

        pub fn add(self: *Self, gpa: Allocator, idx: IndexT, item: T) Allocator.Error!void {
            if (self.dense.len <= self.len) {
                try self.growDenseAndInverse(gpa, self.len + 1);
            }

            const dense_idx = self.len;
            self.len += 1;
            errdefer self.len -= 1;

            self.dense[dense_idx] = item;
            self.inverse[dense_idx] = idx;

            const page_idx = pageIndex(idx);
            if (self.spares.len <= page_idx) {
                @branchHint(.unlikely);
                try self.growSparse(gpa, @max(page_idx, 1));
                self.spares[page_idx] = try gpa.alloc(?usize, page_size.size());
            } else if (self.spares[page_idx] == null) {
                @branchHint(.unlikely);
                self.spares[page_idx] = try gpa.alloc(?usize, page_size.size());
            }

            const sparse_slot = self.getSparseSlot(idx);
            sparse_slot.* = dense_idx;
        }

        pub fn remove(self: *Self, idx: IndexT) void {
            const dense_idx = self.getDenseIdx(idx) orelse
                return;

            if (self.dense.len == 1) {
                @branchHint(.cold);
                self.getSparseSlot(idx).* = null;
                return;
            }

            const last_idx = self.inverse[self.len - 1];
            self.dense[dense_idx] = self.dense[self.len - 1];
            self.inverse[dense_idx] = last_idx;
            self.getSparseSlot(last_idx).* = self.getSparseSlot(idx).*;

            self.len -= 1;
        }

        inline fn pageIndex(idx: IndexT) usize {
            return @intCast(idx >> @intFromEnum(page_size));
        }

        inline fn pageSlot(idx: IndexT) usize {
            return @intCast(idx & page_size.size() - 1);
        }

        fn getDenseIdx(self: *const Self, idx: IndexT) ?usize {
            const page_idx = pageIndex(idx);
            if (self.spares.len <= page_idx) {
                return null;
            }

            const page = self.spares[page_idx] orelse
                return null;

            const slot_idx = pageSlot(idx);
            return page[slot_idx];
        }

        inline fn getSparseSlot(self: *const Self, idx: IndexT) *?usize {
            return &self.spares[pageIndex(idx)].?[pageSlot(idx)];
        }

        fn growSparse(self: *Self, gpa: Allocator, minimum: usize) Allocator.Error!void {
            const new_capacity = minimum +| (minimum / 2);

            if (gpa.resize(self.spares, new_capacity)) {
                @memset(self.spares[self.spares.len..], null);
                self.spares.len = 0;
            } else {
                const old_spares = self.spares;
                self.spares = try gpa.alloc(?Page, new_capacity);
                @memcpy(self.spares[0..old_spares.len], old_spares);
                @memset(self.spares[old_spares.len..], null);
                gpa.free(old_spares);
            }
        }

        fn growDenseAndInverse(self: *Self, gpa: Allocator, minimum: usize) Allocator.Error!void {
            const new_capacity = minimum +| (minimum / 2);

            if (self.inverse.len < new_capacity) {
                if (gpa.resize(self.inverse, new_capacity)) {
                    self.inverse.len = new_capacity;
                } else {
                    const old_inverse = self.inverse;
                    self.inverse = try gpa.alloc(IndexT, new_capacity);
                    @memcpy(self.inverse[0..old_inverse.len], old_inverse);
                    gpa.free(old_inverse);
                }
            }

            // NOTE(freemaker): we check `self.dense` for capacity,
            // so it needs to be the last one which gets expaneded
            if (self.dense.len < new_capacity) {
                if (gpa.resize(self.dense, new_capacity)) {
                    self.dense.len = new_capacity;
                } else {
                    const old_dense = self.dense;
                    self.dense = try gpa.alloc(T, new_capacity);
                    @memcpy(self.dense[0..old_dense.len], old_dense);
                    gpa.free(old_dense);
                }
            }
        }
    };
}

const TestSet = SparseSet(u8, u16, .@"32");

test "SparseSet.add" {
    var set: TestSet = undefined;
    try TestSet.initCapacity(&set, testing.allocator, 32);
    defer set.deinit(testing.allocator);

    try set.add(testing.allocator, 12, 3);
    try set.add(testing.allocator, 3, 10);

    try testing.expectEqualSlices(u8, &.{ 3, 10 }, set.dense[0..set.len]);
}

test "SparseSet.remove" {
    var set: TestSet = undefined;
    try TestSet.initCapacity(&set, testing.allocator, 32);
    defer set.deinit(testing.allocator);

    try set.add(testing.allocator, 12, 3);
    try set.add(testing.allocator, 3, 10);

    set.remove(12);

    try testing.expectEqualSlices(u8, &.{10}, set.dense[0..set.len]);
}
