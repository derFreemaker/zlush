const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");

const IndexedPriorityDequeue = @import("IndexedPriorityDequeue.zig").IndexedPriorityDequeue;
const CircBuffer = @import("CircBuffer.zig").CircBuffer;

/// @Rework
pub fn MultiReaderCircBuffer(comptime T: type) type {
    return struct {
        fn lessThanInteger(ctx: void, a: u32, b: u32) bool {
            _ = ctx;
            return a < b;
        }
        const ReadersQueue = IndexedPriorityDequeue(u32, u8, void, lessThanInteger);
        pub const ReaderIdx = ReadersQueue.Index;

        const Self = @This();

        buf: CircBuffer(T),
        readers: ReadersQueue,

        pub const empty: Self = .{
            .buf = .empty,
            .readers = .empty,
        };

        /// `capacity` and `max_capacity` have to be a power of two
        pub fn initCapacity(self: *Self, gpa: Allocator, capacity: u31, max_capacity: u31, reader_capacity: u8) Allocator.Error!void {
            try CircBuffer(T).initCapacity(&self.buf, gpa, capacity, max_capacity);
            errdefer self.buf.deinit(gpa);

            try ReadersQueue.initCapacity(&self.readers, gpa, undefined, reader_capacity);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.buf.deinit(gpa);
            self.readers.deinit(gpa);
        }

        pub fn registerReader(self: *Self, gpa: Allocator) Allocator.Error!ReaderIdx {
            return try self.readers.push(gpa, self.buf.head);
        }

        pub fn unregisterReader(self: *Self, reader_idx: ReaderIdx) void {
            self.readers.remove(reader_idx);
        }

        pub fn usage(self: *const Self) u32 {
            return self.buf.usage();
        }

        pub fn availableSpace(self: *const Self) u32 {
            return self.buf.availableSpace();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.buf.isEmpty();
        }

        pub fn isReaderEmpty(self: *const Self, reader_idx: ReaderIdx) bool {
            const head = self.readers.get(reader_idx);

            const perspective = CircBufferPerspective.init(&self.buf, head);
            defer perspective.deinit();

            return self.isEmpty();
        }

        pub fn isFull(self: *const Self) bool {
            return self.usage() == self.capacity;
        }

        fn index(pos: u32, buf_size: u32) u32 {
            return pos & (buf_size - 1);
        }

        /// returns the number of written items from the slice
        pub fn write(self: *Self, gpa: Allocator, slice: []const T) u32 {
            return self.buf.write(gpa, slice);
        }

        /// see `peek` for behaviour
        pub fn read(self: *Self, reader_idx: ReaderIdx, max_n: usize) []const T {
            const data = self.peek(reader_idx, max_n);
            self.toss(reader_idx, @intCast(data.len));
            return data;
        }

        /// returns a view into the ring buffer which is only valid until the next write
        ///
        /// - first reads to the end of the underlying buffer
        ///
        /// - if the reader is at the end, we read from the front of the underlying buffer
        ///
        /// requiring two calls in order to read both,
        /// if the buffer is currently wrapping and the reader is before the wrap
        pub fn peek(self: *Self, reader_idx: ReaderIdx, max_n: usize) []const T {
            const reader_pos = self.readers.get(reader_idx);

            const perspective = CircBufferPerspective.init(&self.buf, reader_pos);
            defer perspective.deinit();

            return self.buf.peek(max_n);
        }

        pub fn toss(self: *Self, reader_idx: ReaderIdx, n: u32) void {
            const reader_pos = self.readers.get(reader_idx);
            self.readers.update(reader_idx, reader_pos + n);
            self.buf.head = self.readers.peek().?;
        }

        pub const CircBufferPerspective = struct {
            buf: *CircBuffer(T),
            previous_head: u32,

            pub fn init(buf: *CircBuffer(T), new_head: u32) CircBufferPerspective {
                const perspective = CircBufferPerspective{
                    .buf = buf,
                    .previous_head = buf.head,
                };
                buf.head = new_head;
                return perspective;
            }

            pub fn deinit(self: *const CircBufferPerspective) void {
                self.buf.head = self.previous_head;
            }
        };
    };
}

const TestBuffer = MultiReaderCircBuffer(u8);

test "write - no reader" {
    var buf: TestBuffer = undefined;
    try TestBuffer.initCapacity(&buf, testing.allocator, 1024, 4 * 1024, 1);
    defer buf.deinit(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);
}

test "write" {
    var buf: TestBuffer = undefined;
    try TestBuffer.initCapacity(&buf, testing.allocator, 1024, 4 * 1024, 1);
    defer buf.deinit(testing.allocator);

    _ = try buf.registerReader(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);
}

test "read" {
    var buf: TestBuffer = undefined;
    try TestBuffer.initCapacity(&buf, testing.allocator, 1024, 4 * 1024, 1);
    defer buf.deinit(testing.allocator);

    const reader = try buf.registerReader(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    const slice = buf.read(reader, 4 * 1024);
    try testing.expectEqualStrings(str, slice);
}

test "two readers" {
    var buf: TestBuffer = undefined;
    try TestBuffer.initCapacity(&buf, testing.allocator, 1024, 4 * 1024, 1);
    defer buf.deinit(testing.allocator);

    const reader1 = try buf.registerReader(testing.allocator);
    const reader2 = try buf.registerReader(testing.allocator);

    const str = "test string";
    _ = buf.write(testing.allocator, str);

    const slice1 = buf.read(reader1, 4 * 1024);
    try testing.expectEqualStrings(str, slice1);

    const slice2 = buf.read(reader2, 32);
    try testing.expectEqualStrings(str[0..11], slice2);
}

test "wrap" {
    var buf: TestBuffer = undefined;
    try TestBuffer.initCapacity(&buf, testing.allocator, 32, 32, 1);
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
    try TestBuffer.initCapacity(&buf, testing.allocator, 16, 16, 1);
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
