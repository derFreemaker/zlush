const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const IndexedPriorityDequeue = @import("IndexedPriorityDequeue.zig").IndexedPriorityDequeue;

fn lessThanInteger(ctx: void, a: usize, b: usize) bool {
    _ = ctx;
    return a < b;
}
const ReadersQueue = IndexedPriorityDequeue(usize, u8, void, lessThanInteger);
const ReaderIdx = ReadersQueue.Index;

/// @Rework
pub fn MultiReaderCircBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        start: usize,
        end: usize,
        max_capacity: ?usize,

        readers: ReadersQueue,

        pub const empty: Self = .{
            .buf = &.{},
            .start = 0,
            .end = 0,
            .max_capacity = null,

            .readers = .empty,
        };

        pub fn init(self: *Self, gpa: Allocator, capacity: usize, reader_capacity: u8, max_capacity: ?usize) Allocator.Error!void {
            self.buf = try gpa.alloc(T, capacity);
            errdefer gpa.free(self.buf);

            self.start = 0;
            self.end = 0;
            self.max_capacity = max_capacity;

            try ReadersQueue.initCapacity(&self.readers, gpa, undefined, reader_capacity);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buf);
            self.readers.deinit(gpa);
        }

        /// returns `false` when the internal buffer is already at `max_capacity`
        fn grow(self: *Self, gpa: Allocator) Allocator.Error!void {
            if (self.max_capacity != null and
                self.buf.len == self.max_capacity.?)
            {
                return;
            }

            // @Improve
            var new_len = self.buf.len * 2;
            if (self.max_capacity) |max_cap| {
                new_len = @max(new_len, max_cap);
            }

            if (gpa.resize(self.buf, new_len)) {
                self.buf.len = new_len;
            } else {
                const old_buf = self.buf;
                self.buf = try gpa.alloc(T, new_len);
                @memcpy(self.buf[0..old_buf.len], old_buf);
                gpa.free(old_buf);
            }
        }

        inline fn avaiableSpace(self: *Self) usize {
            const diff = self.end -% self.start;
            const mask = @as(usize, @intFromBool(diff > self.buf.len)) *% self.buf.len;
            return diff +% mask;
        }

        /// returns the number of written items from the slice
        pub fn write(self: *Self, gpa: Allocator, slice: []const T) usize {
            if (self.readers.len == 0) {
                return slice.len;
            }

            const avaiable_space = self.avaiableSpace();
            if (avaiable_space <= slice.len) {
                // we can try to grow, but we dont need to
                self.grow(gpa) catch {};
            }

            const buf_end = if (self.end < self.start) self.start else self.buf.len;

            const tail_space = buf_end - self.end;
            const tail_write_len = @min(slice.len, tail_space);
            @memcpy(self.buf[self.end .. self.end + tail_write_len], slice[0..tail_write_len]);
            self.end += tail_write_len;

            const head_pos = if (self.end < self.start) self.end else 0;
            const head_space = if (self.end < self.start)
                // we keep one slot free to make `start == end`
                // an unambiguous state for an empty buffer
                self.start - self.end - 1
            else
                self.start;
            const head_write_len = @min(slice.len - tail_write_len, head_space);
            @memcpy(self.buf[head_pos .. head_pos + head_write_len], slice[tail_write_len .. tail_write_len + head_write_len]);
            if (self.end < self.start) {
                self.end += head_write_len;
            } else if (self.end == self.buf.len) {
                self.end = head_write_len;
            } else {
                std.debug.assert(head_write_len == 0);
            }

            return tail_write_len + head_write_len;
        }

        pub fn registerReader(self: *Self, gpa: Allocator) Allocator.Error!ReaderIdx {
            return try self.readers.push(gpa, self.start);
        }

        pub fn unregisterReader(self: *Self, reader: ReaderIdx) void {
            self.readers.remove(reader);

            if (self.readers.len == 0) {
                self.start = 0;
                self.end = 0;
            }
        }

        /// we first read the back section and if that is empty we read the front section
        /// requiring two calls in order to read both
        pub fn read(self: *Self, reader: ReaderIdx, max_n: usize) []const T {
            var reader_pos = self.readers.get(reader);
            defer self.readers.update(reader, reader_pos);

            var data: []const u8 = &.{};
            if (reader_pos < self.end) {
                const read_len = @min(self.end - reader_pos, max_n);
                data = self.buf[reader_pos .. reader_pos + read_len];
                reader_pos = reader_pos + read_len;
            } else if (reader_pos < self.buf.len) {
                const read_len = @min(self.buf.len - reader_pos, max_n);
                data = self.buf[reader_pos .. reader_pos + read_len];
                reader_pos = reader_pos + read_len;
            } else if (reader_pos == self.buf.len) {
                const read_len = @min(self.end, max_n);
                data = self.buf[0..read_len];
                reader_pos = read_len;
            } else {
                unreachable;
            }

            if (self.readers.peekIdx().? == reader) {
                self.start = reader_pos;
            }

            return data;
        }
    };
}

const TestBuffer = MultiReaderCircBuffer(u8);

test "no reader / no-op" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    try testing.expectEqual(0, buf.start);
    try testing.expectEqual(0, buf.end);
}

test "one reader / write" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    _ = try buf.registerReader(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    try testing.expectEqual(0, buf.start);
    try testing.expectEqual(str.len, buf.end);
    try testing.expectEqualStrings(str, buf.buf[0..buf.end]);
}

test "one reader / read" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    const reader = try buf.registerReader(testing.allocator);

    const str = "test string";
    const written = buf.write(testing.allocator, str);
    try testing.expectEqual(str.len, written);

    try testing.expectEqual(0, buf.start);
    try testing.expectEqual(str.len, buf.end);
    try testing.expectEqualStrings(str, buf.buf[0..buf.end]);

    const slice = buf.read(reader, 4 * 1024);
    try testing.expectEqualStrings(str, slice);

    try testing.expectEqual(str.len, buf.start);
    try testing.expectEqual(str.len, buf.end);
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

    try testing.expectEqual(0, buf.start);

    const slice2 = buf.read(reader2, 8);
    try testing.expectEqualStrings(str[0..8], slice2);

    try testing.expectEqual(8, buf.start);
}

test "unregister last reader" {
    var buf: TestBuffer = undefined;
    try TestBuffer.init(&buf, testing.allocator, 1024, 1, 4 * 1024);
    defer buf.deinit(testing.allocator);

    const reader = try buf.registerReader(testing.allocator);

    const str = "test string";
    _ = buf.write(testing.allocator, str);

    buf.unregisterReader(reader);
    try testing.expectEqual(0, buf.start);
    try testing.expectEqual(0, buf.end);
}
