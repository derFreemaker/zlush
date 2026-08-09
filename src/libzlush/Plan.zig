const std = @import("std");

const IndexT = @import("index.zig").IndexT;

pub const FileIdx = IndexT(TrackedFile, u16);
pub const ExecIdx = IndexT(Execution, u16);

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
    args: std.ArrayList(Arg),
    env_map: std.process.Environ.Map,

    stdin: std.ArrayList(Source),
    stdout: std.ArrayList(Sink),
    stderr: std.ArrayList(Sink),

    depends_on: std.ArrayList(ExecIdx),

    pub fn deinit(self: *Execution, allocator: std.mem.Allocator) void {
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);

        self.env_map.deinit();

        self.stdin.deinit(allocator);
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);

        self.depends_on.deinit(allocator);
    }

    pub const Arg = union(enum) {
        str: []const u8,
        exec: Source.ExecSource,

        pub fn deinit(self: *Arg, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .str => |str| allocator.free(str),
                else => {},
            }
        }
    };
};

pub const Source = union(enum) {
    exec: ExecSource,
    file: FileSource,

    pub const ExecSource = struct {
        idx: ExecIdx,
        output: Output,

        pub const Output = struct {
            stdout: bool = true,
            stderr: bool = false,
        };
    };

    pub const FileSource = struct {
        idx: FileIdx,
        accessor: u32,
    };
};

pub const Sink = union(enum) {
    exec: ExecIdx,
    file: FileSink,

    pub const FileSink = struct {
        idx: FileIdx,
        accessor: u32,
        mode: Mode,

        pub const Mode = enum {
            append,
            write_truc,
        };
    };
};
