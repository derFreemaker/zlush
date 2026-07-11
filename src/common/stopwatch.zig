const std = @import("std");

const Stopwatch = @This();

allocator: std.mem.Allocator,

stack: [64]usize,
cur_idx: usize,

sections: std.ArrayList(Section),

const Section = struct {
    name: []const u8,
    start_time: i64,
    end_time: ?i64,
    parent: ?usize,
    depth: usize,
};

pub fn init(allocator: std.mem.Allocator) !Stopwatch {
    return .{
        .allocator = allocator,

        .stack = undefined,
        .cur_idx = 0,

        .sections = try .initCapacity(allocator, 32),
    };
}

pub fn deinit(self: *Stopwatch) void {
    for (self.sections.items) |section| {
        self.allocator.free(section.name);
    }
    self.sections.deinit(self.allocator);
}

pub fn begin(self: *Stopwatch, name: []const u8) error{OutOfMemory}!void {
    const parent = if (self.cur_idx > 0) self.stack[self.cur_idx - 1] else null;
    const depth = self.cur_idx;

    const section = Section{
        .name = try self.allocator.dupe(u8, name),
        .start_time = std.time.microTimestamp(),
        .end_time = null,
        .parent = parent,
        .depth = depth,
    };

    try self.sections.append(self.allocator, section);
    const index = self.sections.items.len - 1;
    self.stack[self.cur_idx] = index;
    self.cur_idx += 1;
}

pub fn end(self: *Stopwatch) void {
    if (self.cur_idx == 0) return;

    self.cur_idx -= 1;
    const index = self.stack[self.cur_idx];
    self.sections.items[index].end_time = std.time.microTimestamp();
}

pub fn display(self: *Stopwatch, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (self.sections.items) |section| {
        var i: usize = 0;
        while (i < section.depth) : (i += 1) {
            try writer.writeAll("  ");
        }

        try writer.print("{s}: ", .{section.name});

        if (section.end_time) |end_time| {
            const duration_us = end_time - section.start_time;
            try prettyPrintMicroseconds(writer, @floatFromInt(duration_us));
        } else {
            try writer.print("open", .{});
        }

        try writer.writeByte('\n');
    }
}

fn prettyPrintMicroseconds(writer: *std.Io.Writer, microseconds: f64) std.Io.Writer.Error!void {
    const us = microseconds;

    // Convert to different units
    const ms = us / 1000.0;
    const s = ms / 1000.0;
    const m = s / 60.0;
    const h = m / 60.0;

    if (us < 1000.0) {
        // Less than 1ms: show microseconds
        try writer.print("{d}μs", .{us});
    } else if (ms < 1000.0) {
        // Less than 1s: show milliseconds
        try writer.print("{d:.2}ms", .{ms});
    } else if (s < 60.0) {
        // Less than 1min: show seconds
        try writer.print("{d:.2}s", .{s});
    } else if (m < 60.0) {
        // Less than 1hr: show minutes and seconds
        const mins = @as(u64, @intFromFloat(m));
        const secs = @as(u64, @intFromFloat(s)) % 60;
        try writer.print("{d}m {d}s", .{ mins, secs });
    } else {
        // 1hr or more: show hours and minutes
        const hours = @as(u64, @intFromFloat(h));
        const mins = @as(u64, @intFromFloat(m)) % 60;
        try writer.print("{d}h {d}m", .{ hours, mins });
    }
}

pub const Disabled = struct {
    pub fn init(_: std.mem.Allocator) !Disabled {
        return Disabled{};
    }
    pub fn deinit(_: *Disabled) void {}

    pub fn begin(_: *Disabled, _: []const u8) error{OutOfMemory}!void {}
    pub fn end(_: *Disabled) void {}
    pub fn display(_: *Disabled, _: *std.Io.Writer) std.Io.Writer.Error!void {}
};

// // Example usage:
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     var profiler = try Profiler.init(allocator);
//     defer profiler.deinit();
//
//     {
//         try profiler.start("Shell Initialization");
//         defer profiler.end();
//         std.Thread.sleep(50 * std.time.ns_per_ms);
//
//         {
//             try profiler.start("Loading Config");
//             defer profiler.end();
//             std.Thread.sleep(30 * std.time.ns_per_ms);
//
//             {
//                 try profiler.start("Parsing Config");
//                 defer profiler.end();
//                 std.Thread.sleep(15 * std.time.ns_per_ms);
//             }
//
//             {
//                 try profiler.start("Applying Settings");
//                 defer profiler.end();
//                 std.Thread.sleep(10 * std.time.ns_per_ms);
//             }
//         }
//
//         {
//             try profiler.start("Loading History");
//             defer profiler.end();
//             std.Thread.sleep(40 * std.time.ns_per_ms);
//         }
//
//         {
//             try profiler.start("Initializing Prompt");
//             defer profiler.end();
//             std.Thread.sleep(20 * std.time.ns_per_ms);
//         }
//     }
//
//     var buf: [256]u8 = undefined;
//     var stderr = std.fs.File.stdout().writer(&buf);
//     const writer = &stderr.interface;
//
//     try writer.writeAll("-- Shell Timings --\n");
//     try profiler.display(writer);
//     try writer.flush();
// }
