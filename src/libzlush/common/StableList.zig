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

        pub fn get(self: *const Self, index: Index) *T {
            return self.sparse.get(index.value());
        }

        pub fn addOne(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Index {
            const offset = self.dense.items.len;
            _ = offset; // autofix
            _ = try self.dense.addOne(gpa);
            errdefer _ = self.dense.pop();

            const index = self.free_indexes.pop() orelse blk: {
                const index = Index.fromAny(self.sparse.items.len) catch return error.OutOfMemory;

                break :blk index;
            };

            _ = try self.data.addOne(gpa);
            errdefer _ = self.data.pop();

            try self.free_indexes.ensureTotalCapacity(self.data.capacity);

            return index;
        }

        pub fn append(self: *Self, gpa: std.mem.Allocator, item: T) std.mem.Allocator.Error!Index {
            const index = try self.addOne(gpa);
            errdefer self.remove(index);

            const ptr = self.get(index);
            ptr.* = item;

            return index;
        }

        pub fn remove(self: *Self, index: Index) void {
            self.free_indexes.appendAssumeCapacity(index);
        }
    };
}
