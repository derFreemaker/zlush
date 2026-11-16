const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Indexes = @import("index.zig");

pub fn IndexedPriorityQueue(
    comptime T: type,
    comptime IndexT: type,
    comptime Context: type,
    comptime lessThanFn: fn (context: Context, a: T, b: T) bool,
) type {
    return struct {
        pub const Index = Indexes.IndexT(Self, IndexT);

        const Self = @This();

        nodes: []T,
        queue_map: []IndexT,
        inverse_queue_map: []Index,
        free_indexes: []Index,
        len: IndexT,
        capacity: IndexT,

        context: Context,

        pub const empty: Self = .{
            .nodes = &.{},
            .queue_map = &.{},
            .inverse_queue_map = &.{},
            .free_indexes = &.{},
            .len = 0,
            .capacity = 0,

            .context = undefined,
        };

        pub fn initCapacity(
            self: *Self,
            gpa: Allocator,
            context: Context,
            capacity: IndexT,
        ) Allocator.Error!void {
            self.nodes = try gpa.alloc(T, capacity);
            errdefer gpa.free(self.nodes);

            self.queue_map = try gpa.alloc(IndexT, capacity);
            errdefer gpa.free(self.queue_map);

            self.inverse_queue_map = try gpa.alloc(Index, capacity);
            errdefer gpa.free(self.inverse_queue_map);

            self.free_indexes = try gpa.alloc(Index, capacity);
            errdefer gpa.free(self.free_indexes[0..self.capacity]);
            self.free_indexes.len = 0;

            self.len = 0;
            self.capacity = capacity;

            self.context = context;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.nodes);
            gpa.free(self.queue_map);
            gpa.free(self.inverse_queue_map);
            gpa.free(self.free_indexes.ptr[0..self.capacity]);
            self.len = 0;
        }

        pub fn get(self: *const Self, idx: Index) T {
            return self.nodes[idx.value()];
        }

        pub fn peek(self: *const Self) ?T {
            if (self.len == 0) {
                return null;
            }

            return self.nodes[self.inverse_queue_map[0].value()];
        }

        pub fn peekIdx(self: *const Self) ?Index {
            if (self.len == 0) {
                return null;
            }

            return self.inverse_queue_map[0];
        }

        pub fn push(self: *Self, gpa: Allocator, item: T) Allocator.Error!Index {
            try self.ensureUnusedCapacity(gpa, 1);
            return self.pushAssumeCapacity(item) catch return Allocator.Error.OutOfMemory;
        }

        pub fn pushAssumeCapacity(self: *Self, item: T) error{IndexOverflow}!Index {
            const idx: Index = blk: {
                if (self.free_indexes.len > 0) {
                    const idx = self.free_indexes[self.free_indexes.len - 1];
                    self.free_indexes.len -= 1;
                    break :blk idx;
                }

                break :blk Index.fromAny(self.len) catch return error.IndexOverflow;
            };

            self.nodes[idx.value()] = item;
            self.queue_map[idx.value()] = self.len;
            self.inverse_queue_map[self.len] = idx;
            self.len += 1;

            self.siftUp(idx);
            return idx;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            }

            const first_node_idx: Index = self.inverse_queue_map[0];
            const first_node = self.get(first_node_idx);
            self.remove(first_node_idx);

            return first_node;
        }

        pub fn remove(self: *Self, idx: Index) void {
            if (self.len == 0) {
                return;
            }

            const last_node: Index = self.inverse_queue_map[self.len - 1];
            self.swap(idx, last_node);
            self.len -= 1;

            self.siftDown(last_node);

            self.free_indexes.len += 1;
            self.free_indexes[self.free_indexes.len - 1] = idx;
        }

        pub fn update(self: *Self, idx: Index, item: T) void {
            self.nodes[idx.value()] = item;

            self.siftDown(idx);

            // @Performance: we can not / dont have to check,
            // move up if we moved down before
            self.siftUp(idx);
        }

        fn swap(self: *Self, a: Index, b: Index) void {
            if (a == b) {
                return;
            }

            const a_pos = self.queue_map[a.value()];
            const b_pos = self.queue_map[b.value()];

            self.moveNode(a, b_pos);
            self.moveNode(b, a_pos);
        }

        fn moveNode(self: *Self, node: Index, pos: IndexT) void {
            self.queue_map[node.value()] = pos;
            self.inverse_queue_map[pos] = node;
        }

        fn siftUp(self: *Self, idx: Index) void {
            const node = self.get(idx);
            var node_pos: IndexT = self.queue_map[idx.value()];
            while (node_pos > 0) {
                const parent_pos = (node_pos - 1) >> 1;
                const parent_idx: Index = self.inverse_queue_map[parent_pos];
                const parent = self.get(parent_idx);
                if (lessThanFn(self.context, parent, node))
                    break;

                self.moveNode(parent_idx, node_pos);
                node_pos = parent_pos;
            }
            self.moveNode(idx, node_pos);
        }

        fn siftDown(self: *Self, idx: Index) void {
            const node = self.get(idx);
            var node_pos: IndexT = self.queue_map[idx.value()];
            while (node_pos + 1 < self.len) {
                const left_child_pos = node_pos * 2 + 1;
                if (left_child_pos < self.len) {
                    const left_child_idx: Index = self.inverse_queue_map[left_child_pos];
                    const left_child = self.get(left_child_idx);
                    if (lessThanFn(self.context, left_child, node)) {
                        self.moveNode(left_child_idx, node_pos);
                        node_pos = left_child_pos;
                        continue;
                    }
                }

                const right_child_pos = node_pos * 2 + 2;
                if (right_child_pos < self.len) {
                    const right_child_idx: Index = self.inverse_queue_map[right_child_pos];
                    const right_child = self.get(right_child_idx);
                    if (lessThanFn(self.context, right_child, node)) {
                        self.moveNode(right_child_idx, node_pos);
                        node_pos = right_child_pos;
                        continue;
                    }
                }

                break;
            }
            self.moveNode(idx, node_pos);
        }

        pub fn ensureTotalCapacity(self: *Self, gpa: Allocator, minimum: IndexT) Allocator.Error!void {
            const new_capacity = minimum +| (minimum / 2);

            if (self.nodes.len < new_capacity) {
                if (gpa.resize(self.nodes, new_capacity)) {
                    self.nodes.len = new_capacity;
                } else {
                    const old_values = self.nodes;
                    self.nodes = try gpa.alloc(T, new_capacity);
                    @memcpy(self.nodes[0..old_values.len], old_values);
                    gpa.free(old_values);
                }
            }

            if (self.queue_map.len < new_capacity) {
                if (gpa.resize(self.queue_map, new_capacity)) {
                    self.queue_map.len = new_capacity;
                } else {
                    const old_queue_map = self.queue_map;
                    self.queue_map = try gpa.alloc(IndexT, new_capacity);
                    @memcpy(self.queue_map[0..old_queue_map.len], old_queue_map);
                    gpa.free(old_queue_map);
                }
            }

            if (self.inverse_queue_map.len < new_capacity) {
                if (gpa.resize(self.inverse_queue_map, new_capacity)) {
                    self.inverse_queue_map.len = new_capacity;
                } else {
                    const old_inverse_queue_map = self.inverse_queue_map;
                    self.inverse_queue_map = try gpa.alloc(Index, new_capacity);
                    @memcpy(self.inverse_queue_map[0..old_inverse_queue_map.len], old_inverse_queue_map);
                    gpa.free(old_inverse_queue_map);
                }
            }

            if (self.free_indexes.len < new_capacity) {
                if (!gpa.resize(self.free_indexes, new_capacity)) {
                    const old_free_indexes = self.free_indexes;
                    self.free_indexes = try gpa.alloc(Index, new_capacity);
                    self.free_indexes.len = old_free_indexes.len;
                    @memcpy(self.free_indexes, old_free_indexes);
                    gpa.free(old_free_indexes.ptr[0..self.capacity]);
                }
            }

            self.capacity = new_capacity;
        }

        pub fn ensureUnusedCapacity(self: *Self, gpa: Allocator, additional_count: IndexT) Allocator.Error!void {
            return self.ensureTotalCapacity(gpa, self.len + additional_count);
        }
    };
}

fn lessThanInteger(ctx: void, a: u32, b: u32) bool {
    _ = ctx;
    return a < b;
}

test "push" {
    var pq: IndexedPriorityQueue(u32, u32, void, lessThanInteger) = .empty;
    defer pq.deinit(testing.allocator);

    _ = try pq.push(testing.allocator, 12);
    _ = try pq.push(testing.allocator, 3);
    _ = try pq.push(testing.allocator, 5);

    try testing.expectEqual(3, pq.pop());
    try testing.expectEqual(5, pq.pop());
    try testing.expectEqual(12, pq.pop());
    try testing.expectEqual(null, pq.pop());
}

test "remove" {
    var pq: IndexedPriorityQueue(u32, u32, void, lessThanInteger) = .empty;
    defer pq.deinit(testing.allocator);

    _ = try pq.push(testing.allocator, 12);
    _ = try pq.push(testing.allocator, 3);
    const idx = try pq.push(testing.allocator, 5);

    pq.remove(idx);

    try testing.expectEqual(3, pq.pop());
    try testing.expectEqual(12, pq.pop());
    try testing.expectEqual(null, pq.pop());
}

test "update" {
    var pq: IndexedPriorityQueue(u32, u32, void, lessThanInteger) = .empty;
    defer pq.deinit(testing.allocator);

    _ = try pq.push(testing.allocator, 5);
    const idx = try pq.push(testing.allocator, 12);
    _ = try pq.push(testing.allocator, 3);

    pq.update(idx, 1);

    try testing.expectEqual(1, pq.pop());
    try testing.expectEqual(3, pq.pop());
    try testing.expectEqual(5, pq.pop());
}
