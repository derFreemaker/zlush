const std = @import("std");

const IndexT = @import("index.zig").IndexT;

pub fn StableList(comptime T: type, comptime IndexSize: type) type {
    if (@typeInfo(IndexSize) != .int) @compileError("expected IndexSize of type 'int' found: " ++ @typeName(IndexSize));
    if (@typeInfo(IndexSize).int.signedness != .unsigned) @compileError("expected IndexSize to be 'unsigned' found: " ++ @typeName(IndexSize));

    return struct {
        pub const Index = IndexT(T, IndexSize);

        const Self = @This();

        data: std.ArrayList(T),

        pub const empty = Self{
            .data = .empty,
        };

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: IndexSize) std.mem.Allocator.Error!Self {
            var data = try std.ArrayList(T).initCapacity(allocator, capacity);
            errdefer data.deinit(allocator);

            return Self{
                .data = data,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
        }

        pub fn get(self: *const Self, index: Index) *T {
            return &self.data.items[index.value()];
        }

        pub fn addOne(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Index {
            const index = Index.fromAny(self.data.items.len) catch return error.OutOfMemory;

            _ = try self.data.addOne(allocator);
            errdefer _ = self.data.pop();

            return index;
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, item: T) std.mem.Allocator.Error!Index {
            const index = Index.fromAny(self.data.items.len) catch return error.OutOfMemory;

            const ptr = try self.data.addOne(allocator);
            errdefer _ = self.data.pop();
            ptr.* = item;

            return index;
        }

        /// removes the last item, should only be used for `errdefer`
        pub fn pop(self: *Self) void {
            _ = self.data.pop();
        }
    };
}
