const std = @import("std");

const Indexes = @import("index.zig");
const SparseSet = @import("SparseSet.zig").SparseSet;

pub fn StableList(comptime T: type, comptime IndexT: type) type {
    if (@typeInfo(IndexT) != .int) @compileError("expected IndexSize of type 'int' found: " ++ @typeName(IndexT));
    if (@typeInfo(IndexT).int.signedness != .unsigned) @compileError("expected IndexSize to be 'unsigned' found: " ++ @typeName(IndexT));

    return struct {
        pub const Index = Indexes.IndexT(T, IndexT);

        const Set = SparseSet(T, IndexT, .@"64");

        const Self = @This();

        sparse: Set,
        free_indexes: std.ArrayList(Index),

        pub const empty = Self{
            .sparse = .empty,
            .free_indexes = .empty,
        };

        pub fn initCapacity(self: *Self, gpa: std.mem.Allocator, capacity: IndexT) std.mem.Allocator.Error!void {
            try Set.initCapacity(&self.sparse, gpa, capacity);
            errdefer self.sparse.deinit(gpa);

            self.free_indexes = try .initCapacity(gpa, capacity);
            errdefer self.free_indexes.deinit(gpa);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.sparse.deinit(gpa);
            self.free_indexes.deinit(gpa);
        }

        pub fn len(self: *const Self) usize {
            return self.sparse.len;
        }

        pub fn items(self: *const Self) []T {
            return self.sparse.items();
        }

        pub fn get(self: *const Self, index: Index) *T {
            return self.sparse.get(index.value()).?;
        }

        pub fn addOne(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Index {
            const idx = self.free_indexes.pop() orelse blk: {
                const index = Index.fromAny(self.sparse.len) catch return error.OutOfMemory;
                try self.free_indexes.ensureTotalCapacity(self.sparse.len);
                break :blk index;
            };

            try self.sparse.set(gpa, idx.value(), undefined);

            return idx;
        }

        pub fn append(self: *Self, gpa: std.mem.Allocator, item: T) std.mem.Allocator.Error!Index {
            const idx = self.free_indexes.pop() orelse blk: {
                const index = Index.fromAny(self.sparse.len) catch return error.OutOfMemory;
                try self.free_indexes.ensureTotalCapacity(gpa, self.sparse.len);
                break :blk index;
            };

            try self.sparse.set(gpa, idx.value(), item);

            return idx;
        }

        pub fn remove(self: *Self, idx: Index) void {
            self.free_indexes.appendAssumeCapacity(idx);
            self.sparse.remove(idx.value());
        }
    };
}
