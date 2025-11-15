const std = @import("std");

pub const Profiler = struct {
    sections: std.ArrayList(Section),
    stack: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    const Section = struct {
        name: []const u8,
        start_time: i64,
        end_time: ?i64,
        parent: ?usize,
        depth: usize,
    };

    pub fn init(allocator: std.mem.Allocator) !Profiler {
        return .{
            .sections = try .initCapacity(allocator, 32),
            .stack = try .initCapacity(allocator, 16),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Profiler) void {
        self.sections.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    pub fn start(self: *Profiler, name: []const u8) !void {
        const parent = if (self.stack.items.len > 0) self.stack.items[self.stack.items.len - 1] else null;
        const depth = self.stack.items.len;

        const section = Section{
            .name = name,
            .start_time = std.time.microTimestamp(),
            .end_time = null,
            .parent = parent,
            .depth = depth,
        };

        try self.sections.append(self.allocator, section);
        const index = self.sections.items.len - 1;
        try self.stack.append(self.allocator, index);
    }

    pub fn end(self: *Profiler) void {
        if (self.stack.items.len == 0) return;

        const index = self.stack.pop().?;
        self.sections.items[index].end_time = std.time.microTimestamp();
    }

    pub fn display(self: *Profiler, writer: *std.Io.Writer) !void {
        for (self.sections.items) |section| {
            if (section.end_time) |end_time| {
                const duration_ns = end_time - section.start_time;
                const duration_ms = @as(f64, @floatFromInt(duration_ns)) / std.time.us_per_ms;

                // Print indentation
                var i: usize = 0;
                while (i < section.depth) : (i += 1) {
                    try writer.writeAll("  ");
                }

                try writer.print("{s}: {d:.1}ms\n", .{ section.name, duration_ms });
            }
        }
    }
};

// 
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
