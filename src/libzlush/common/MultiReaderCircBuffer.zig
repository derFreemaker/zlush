const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");

const IndexedPriorityDequeue = @import("IndexedPriorityDequeue.zig").IndexedPriorityDequeue;

fn lessThanInteger(ctx: void, a: u32, b: u32) bool {
    _ = ctx;
    return a < b;
}
const ReadersQueue = IndexedPriorityDequeue(u32, u8, void, lessThanInteger);
const ReaderIdx = ReadersQueue.Index;

/// @Rework
pub fn MultiReaderCircBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: if (builtin.mode == .Debug) []T else [*]T,
        capacity: u32,
        max_capacity: u32,

        head: u32,
        tail: u32,

        readers: ReadersQueue,

        pub const empty: Self = .{
            .buf = &.{},
            .capacity = 0,
            .max_capacity = null,

            .head = 0,
            .tail = 0,

            .readers = .empty,
        };

        /// `capacity` and `max_capacity` have to be a power of two
        /// and can not be bigger than `2^31`.
        pub fn init(self: *Self, gpa: Allocator, capacity: u32, reader_capacity: u8, max_capacity: u32) Allocator.Error!void {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            std.debug.assert(capacity < (1 << 31));
            std.debug.assert(std.math.isPowerOfTwo(max_capacity));
            std.debug.assert(max_capacity < (1 << 31));
            const init_capacity: u32 = @max(capacity, max_capacity);

            const buf = try gpa.alloc(T, init_capacity);
            errdefer gpa.free(buf);
            self.buf = if (builtin.mode == .Debug) buf else buf.ptr;

            self.capacity = init_capacity;
            self.max_capacity = max_capacity;

            self.head = 0;
            self.tail = 0;

            try ReadersQueue.initCapacity(&self.readers, gpa, undefined, reader_capacity);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buf[0..self.capacity]);
            self.readers.deinit(gpa);
        }

        /// returns `false` when the internal buffer is already at `max_capacity`
        fn grow(self: *Self, gpa: Allocator) Allocator.Error!void {
            if (self.capacity == self.max_capacity) {
                return;
            }
            const new_len = @max(self.capacity << 1, self.max_capacity);

            if (gpa.resize(self.buf[0..self.capacity], new_len)) {
                self.capacity = new_len;
            } else {
                const old_buf = self.buf[0..self.capacity];
                const new_buf = try gpa.alloc(T, new_len);
                self.buf = if (builtin.mode == .Debug) new_buf else new_buf.ptr;
                @memcpy(self.buf[0..old_buf.len], old_buf);
                gpa.free(old_buf);
            }
        }

        pub fn usage(self: *const Self) u32 {
            return self.tail -% self.head;
        }

        pub fn availableSpace(self: *const Self) u32 {
            return self.capacity - self.usage();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == self.tail;
        }

        pub fn isReaderEmpty(self: *const Self, reader: ReaderIdx) bool {
            const head = self.readers.get(reader);
            return head == self.tail;
        }

        pub fn isFull(self: *const Self) bool {
            return self.usage() == self.capacity;
        }

        fn index(pos: u32, buf_size: u32) u32 {
            return pos & (buf_size - 1);
        }

        /// returns the number of written items from the slice
        pub fn write(self: *Self, gpa: Allocator, slice: []const T) u32 {
            if (self.availableSpace() < slice.len) {
                @branchHint(.unlikely);
                // we can try to grow, but we dont need to
                self.grow(gpa) catch {};
            }

            // std.debug.print("-- start write --\n", .{});
            // defer std.debug.print("-- end write --\n", .{});

            if (self.isFull()) {
                // std.debug.print("is full already", .{});
                return 0;
            }

            const space = self.availableSpace();
            const write_len = @min(slice.len, space);
            // std.debug.print("space: {d}; slice.len: {d} -> write_len: {d}\n", .{ space, slice.len, write_len });

            const head_idx = index(self.head, self.capacity);
            const tail_idx = index(self.tail, self.capacity);
            // std.debug.print("head_idx: {d}; tail_idx: {d}\n", .{ head_idx, tail_idx });

            const tail_end = (if (tail_idx < head_idx)
                head_idx
            else
                self.capacity);
            const tail_space = tail_end - tail_idx;
            const tail_write_len = @min(write_len, tail_space);
            // std.debug.print("tail_space: {d} -> tail_write_len: {d}\n", .{ tail_space, tail_write_len });

            // std.debug.print("tail write: {d}..{d}\n", .{ tail_idx, tail_idx + tail_write_len });
            @memcpy(self.buf[tail_idx..][0..tail_write_len], slice[0..tail_write_len]);
            self.tail += tail_write_len;

            const head_end = head_idx;
            const head_pos = index(self.tail, self.capacity);
            // std.debug.print("head_pos: {d}; head_end: {d}\n", .{ head_pos, head_end });

            const head_space = head_end -| head_pos;
            const head_write_len = @min(write_len - tail_write_len, head_space);
            // std.debug.print("head_space: {d} -> head_write_len: {d}\n", .{ head_space, head_write_len });

            // std.debug.print("head write: {d}..{d}\n", .{ head_pos, head_pos + head_write_len });
            @memcpy(self.buf[head_pos..][0..head_write_len], slice[tail_write_len..][0..head_write_len]);
            self.tail += head_write_len;

            // std.debug.print("head: {d}; tail: {d}\n", .{ self.head, self.tail });

            return write_len;
        }

        pub fn registerReader(self: *Self, gpa: Allocator) Allocator.Error!ReaderIdx {
            return try self.readers.push(gpa, self.head);
        }

        pub fn unregisterReader(self: *Self, reader: ReaderIdx) void {
            self.readers.remove(reader);
        }

        /// returns a view into the ring buffer which is only valid until the next write
        ///
        /// - first reads to the end of the underlying buffer
        ///
        /// - if the reader is at the end, we read from the front of the underlying buffer
        ///
        /// requiring two calls in order to read both,
        /// if the buffer is currently wrapping and the reader is before the wrap
        pub fn read(self: *Self, reader: ReaderIdx, max_n: usize) []const T {
            // std.debug.print("-- start read: {d} --\n", .{reader.value()});
            // defer std.debug.print("-- end read: {d} --\n", .{reader.value()});

            if (self.isReaderEmpty(reader)) {
                // std.debug.print("nothing left to read\n", .{});
                return &.{};
            }
            const reader_pos = self.readers.get(reader);

            const reader_idx = index(reader_pos, self.capacity);
            const tail_idx = index(self.tail, self.capacity);
            const upper_bound = if (tail_idx <= reader_idx) self.capacity else tail_idx;
            // std.debug.print("pos: {d}; tail: {d} -> range: {d}..{d}\n", .{ reader_pos, self.tail, reader_idx, upper_bound });

            const read_len = @min(upper_bound - reader_idx, max_n);
            // std.debug.print("read: {d}..{d}\n", .{ reader_idx, reader_idx + read_len });
            const data = self.buf[reader_idx..][0..read_len];

            const new_reader_pos = reader_pos + read_len;
            self.readers.update(reader, new_reader_pos);
            self.head = self.readers.peek().?;

            return data;
        }
    };
}

const TestBuffer = MultiReaderCircBuffer(u8);

test "write - no reader" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    try testing.expectEqual(0, buf.head);
    try testing.expectEqual(str.len, buf.tail);
}

test "write" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    _ = try buf.registerReader(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    try testing.expectEqual(0, buf.head);
    try testing.expectEqual(str.len, buf.tail);
    try testing.expectEqualStrings(str, buf.buf[0..buf.tail]);
}

test "read" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    const reader = try buf.registerReader(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    try testing.expectEqual(0, buf.head);
    try testing.expectEqual(str.len, buf.tail);
    try testing.expectEqualStrings(str, buf.buf[0..buf.tail]);

    const slice = buf.read(reader, 4 * 1024);
    try testing.expectEqualStrings(str, slice);

    try testing.expectEqual(str.len, buf.head);
    try testing.expectEqual(str.len, buf.tail);
}

test "two readers" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    const reader1 = try buf.registerReader(testing.allocator);
    const reader2 = try buf.registerReader(testing.allocator);

    const str = "test string";
    _ = buf.write(testing.allocator, str);

    const slice1 = buf.read(reader1, 4 * 1024);
    try testing.expectEqualStrings(str, slice1);

    try testing.expectEqual(0, buf.head);

    const slice2 = buf.read(reader2, 32);
    try testing.expectEqualStrings(str[0..11], slice2);

    try testing.expectEqual(11, buf.head);
}

test "wrap" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 32, 1, 32);
    defer buf.deinit(testing.allocator);

    const reader = try buf.registerReader(testing.allocator);

    const str = "test string lol";
    _ = buf.write(testing.allocator, str);

    const slice = buf.read(reader, 12);
    try testing.expectEqualStrings(str[0..12], slice);

    const written1 = buf.write(testing.allocator, str);
    try testing.expectEqual(15, written1);
    const written2 = buf.write(testing.allocator, str);
    try testing.expectEqual(14, written2);

    try testing.expectEqual(12, buf.head);
    try testing.expectEqual(44, buf.tail);

    const slice1 = buf.read(reader, 32);
    try testing.expectEqual(20, slice1.len);

    const slice2 = buf.read(reader, 32);
    try testing.expectEqual(12, slice2.len);

    const slice3 = buf.read(reader, 32);
    try testing.expectEqual(0, slice3.len);

    const written3 = buf.write(testing.allocator, str);
    try testing.expectEqual(15, written3);
    const written4 = buf.write(testing.allocator, str);
    try testing.expectEqual(15, written4);
    const written5 = buf.write(testing.allocator, str);
    try testing.expectEqual(2, written5);
}

test "two readers - wrap" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 16, 1, 16);
    defer buf.deinit(testing.allocator);

    const reader1 = try buf.registerReader(testing.allocator);
    const reader2 = try buf.registerReader(testing.allocator);

    const str = "test string";
    _ = buf.write(testing.allocator, str);

    try testing.expectEqualStrings(str, buf.read(reader1, 32));
    try testing.expectEqualStrings(str, buf.read(reader2, 32));

    try testing.expectEqual(11, buf.write(testing.allocator, str));
    try testing.expectEqual(5, buf.write(testing.allocator, str));
    try testing.expectEqualStrings("test ", buf.read(reader1, 32));
    try testing.expectEqualStrings("stringtest ", buf.read(reader1, 32));
    try testing.expectEqualStrings("test ", buf.read(reader2, 32));
    try testing.expectEqualStrings("stringtest ", buf.read(reader2, 32));

    try testing.expectEqual(11, buf.write(testing.allocator, str));

    try testing.expectEqualStrings("test ", buf.read(reader1, 32));
    try testing.expectEqualStrings("string", buf.read(reader1, 32));
    try testing.expectEqualStrings("test ", buf.read(reader2, 32));
    try testing.expectEqualStrings("string", buf.read(reader2, 32));
}
