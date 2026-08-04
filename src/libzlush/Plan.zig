const std = @import("std");

const IndexT = @import("index.zig").IndexT;

pub const FileIdx = IndexT(TrackedFile, u32);
pub const ExecIdx = IndexT(Execution, u32);

const Plan = @This();

allocator: std.mem.Allocator,

env_map: std.process.Environ.Map,

executions: std.ArrayList(Execution),

tracked_files: std.ArrayList(TrackedFile),

pub fn deinit(self: *Plan) void {
    self.env_map.deinit();

    for (self.tracked_files.items) |*tracked_file| {
        tracked_file.deinit(self.allocator);
    }
    self.tracked_files.deinit(self.allocator);

    for (self.executions.items) |*execution| {
        execution.deinit(self.allocator);
    }
    self.executions.deinit(self.allocator);
}

pub const TrackedFile = struct {
    path: []const u8,

    pub fn deinit(self: *TrackedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Execution = struct {
    args: std.ArrayList([]const u8),
    env_map: std.process.Environ.Map,

    stdin: std.ArrayList(Source),
    stdout: std.ArrayList(Sink),
    stderr: std.ArrayList(Sink),

    depends_on: std.ArrayList(ExecIdx),

    pub fn deinit(self: *Execution, allocator: std.mem.Allocator) void {
        for (self.args.items) |arg| {
            allocator.free(arg);
        }
        self.args.deinit(allocator);

        self.env_map.deinit();

        self.stdin.deinit(allocator);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);

        self.depends_on.deinit(allocator);
    }
};

pub const Source = union(enum) {
    execution: ExecSource,
    file: FileSource,

    const ExecSource = struct {
        idx: ExecIdx,
        output: Output,

        pub const Output = struct {
            stdout: bool = true,
            stderr: bool = false,
        };
    };

    const FileSource = struct {
        idx: FileIdx,
        accessor: u32,
    };
};

pub const Sink = union(enum) {
    execution: ExecIdx,
    file: FileSink,

    const FileSink = struct {
        idx: FileIdx,
        accessor: u32,
        mode: Mode,

        const Mode = enum {
            append,
            write_truc,
        };

        const Output = struct {
            stdin: ?Mode = .write_truc,
            stdout: ?Mode = .write_truc,
        };
    };
};
