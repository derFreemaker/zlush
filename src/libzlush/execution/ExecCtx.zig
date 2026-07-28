const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const IndexT = @import("../index.zig").IndexT;
const Plan = @import("../Plan.zig");
const ResolvedPlan = @import("../ResolvedPlan.zig");
const Zlush = @import("../Zlush.zig");

const ExecIdx = IndexT(ExecBuilder, u32);
const FileIdx = IndexT(TrackedFile, u32);

const ExecCtx = @This();

allocator: Allocator,

zlush: *const Zlush,

env_map: std.process.Environ.Map,

executions: std.ArrayList(ExecBuilder),

tracked_files: std.ArrayList(TrackedFile),
// TODO: add file path resolve cache to avoid calling the FS for every time
// files_resolve_cache: std.hash_map.StringHashMap([]const u8),
tracked_files_map: std.hash_map.StringHashMapUnmanaged(FileIdx),

pub fn init(allocator: Allocator, zlush: *const Zlush) ExecCtx {
    return ExecCtx{
        .allocator = allocator,

        .zlush = zlush,

        .env_map = std.process.Environ.Map.init(allocator),

        .executions = .empty,

        .tracked_files = .empty,
        .tracked_files_map = .empty,
    };
}

pub fn deinit(self: *ExecCtx) void {
    for (self.executions.items) |*execution| {
        execution.deinit();
    }
    self.executions.deinit(self.allocator);

    for (self.tracked_files.items) |*tracked_file| {
        tracked_file.deinit(self.allocator);
    }
    self.tracked_files.deinit(self.allocator);
    self.tracked_files_map.deinit(self.allocator);
}

pub fn setEnvMap(self: *ExecCtx, env_map: std.process.Environ.Map) Allocator.Error!void {
    const clone = try env_map.clone(self.allocator);
    return self.setEnvMapMove(clone);
}

/// takes ownership of `env_map`
pub fn setEnvMapMove(self: *ExecCtx, env_map: std.process.Environ.Map) void {
    self.env_map.deinit();
    self.env_map = env_map;
}

pub fn envMap(self: *ExecCtx) *std.process.Environ.Map {
    return &self.env_map;
}

const GetOrCreateFileIdxError = Allocator.Error || std.Io.File.OpenError || std.Io.File.RealPathError;

fn getOrCreateFileIdx(self: *ExecCtx, io: std.Io, path: []const u8) GetOrCreateFileIdxError!FileIdx {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .path_only = true,
        .allow_directory = false,
    });
    defer file.close(self.io);

    var buf: [64 * 1024]u8 = undefined;
    const buf_realpath = buf[0..try file.realPath(io, &buf)];

    if (self.tracked_files_map.get(buf_realpath)) |idx| {
        return idx;
    }
    const idx: FileIdx = .from(self.tracked_files.items.len);

    const tracked_file = try self.tracked_files.addOne(self.allocator);
    errdefer _ = self.tracked_files.pop();
    tracked_file.* = TrackedFile.init(buf_realpath);
    errdefer tracked_file.deinit(self.allocator);

    try self.tracked_files_map.putNoClobber(self.allocator, tracked_file.path, idx);
    errdefer _ = self.tracked_files_map.remove(tracked_file.path);

    return idx;
}

fn cleanFile(self: *ExecCtx, file_idx: FileIdx) void {
    const tracked_file = &self.tracked_files.items[file_idx.value()];
    if (tracked_file.accessed != 0) {
        return;
    }

    std.debug.assert(file_idx.value() + 1 == self.tracked_files.items.len);
    tracked_file.deinit(self.allocator);
    _ = self.tracked_files.pop();
}

fn getFile(self: *const ExecCtx, file_idx: FileIdx) *TrackedFile {
    return &self.ctx.tracked_files.items[file_idx.value()];
}

pub const ExecCreationError = Allocator.Error || error{
    NoArgProvided,
};

/// requires at least one arg in `args`
/// takes ownership of `env_map`
pub fn exec(self: *ExecCtx, args: []const []const u8) ExecCreationError!*ExecBuilder {
    if (args.len == 0) {
        return ExecCreationError.NoArgProvided;
    }

    if (self.executions.items.len > std.math.maxInt(ExecIdx.UnderlyingT)) {
        return ExecCreationError.OutOfMemory;
    }
    const idx: ExecIdx = .from(@intCast(self.executions.items.len));
    const execution = try self.executions.addOne(self.allocator);
    errdefer _ = self.executions.pop();

    execution.* = try ExecBuilder.init(idx, self, args);
    return execution;
}

pub fn getExec(self: *const ExecCtx, idx: ExecIdx) *ExecBuilder {
    return &self.executions.items[idx.value()];
}

pub fn plan(self: *const ExecCtx, allocator: std.mem.Allocator) Allocator.Error!ResolvedPlan {
    _ = allocator; // autofix
    _ = self; // autofix
    @panic("unimplemented");
}

pub const ExecBuilder = struct {
    idx: ExecIdx,
    ctx: *ExecCtx,

    args: std.ArrayList([]const u8),
    env_map: std.process.Environ.Map,

    stdin: std.ArrayList(Source),
    stdout: std.ArrayList(Sink),
    stderr: std.ArrayList(Sink),

    depends_on: std.ArrayList(ExecIdx),

    fn init(idx: ExecIdx, ctx: *ExecCtx, args_slice: []const []const u8) Allocator.Error!ExecBuilder {
        var args: std.ArrayList([]const u8) = try .initCapacity(ctx.allocator, args_slice.len);
        errdefer {
            for (args.items) |arg| {
                ctx.allocator.free(arg);
            }
            args.deinit(ctx.allocator);
        }
        for (args_slice) |arg| {
            const copy = try ctx.allocator.dupe(u8, arg);
            args.appendAssumeCapacity(copy);
        }

        return ExecBuilder{
            .idx = idx,
            .ctx = ctx,

            .args = args,
            .env_map = std.process.Environ.Map.init(ctx.allocator),

            .stdin = .empty,
            .stdout = .empty,
            .stderr = .empty,

            .depends_on = .empty,
        };
    }

    fn deinit(self: *ExecBuilder) void {
        for (self.args.items) |arg| {
            self.ctx.allocator.free(arg);
        }
        self.args.deinit(self.ctx.allocator);
        self.env_map.deinit();

        self.stdin.deinit(self.ctx.allocator);
        self.stdout.deinit(self.ctx.allocator);
        self.stderr.deinit(self.ctx.allocator);

        self.depends_on.deinit(self.ctx.allocator);
    }

    fn dependsOn(self: *const ExecBuilder, other: ExecIdx) bool {
        if (self.idx == other) {
            return false;
        }

        for (self.depends_on.items) |idx| {
            if (idx == other) {
                return true;
            }

            const execution = self.ctx.getExec(idx);
            if (execution.dependsOn(other)) {
                return true;
            }
        }

        return false;
    }

    pub fn addArgs(self: *ExecBuilder, args: []const []const u8) Allocator.Error!void {
        const args_slice = try self.args.addManyAsSlice(self.ctx.allocator, args.len);
        errdefer self.args.items.len -= args_slice.len;

        var arg_i: usize = 0;
        errdefer for (0..arg_i) |i| {
            self.ctx.allocator.free(args_slice[i]);
        };
        for (args) |arg| {
            args_slice[arg_i] = try self.ctx.allocator.dupe(u8, arg);
            arg_i += 1;
        }
    }

    pub fn setEnvMap(self: *ExecBuilder, env_map: std.process.Environ.Map) Allocator.Error!void {
        const clone = try env_map.clone(self.ctx.allocator);
        return self.setEnvMapMove(clone);
    }

    /// takes ownership of `env_map`
    pub fn setEnvMapMove(self: *ExecBuilder, env_map: std.process.Environ.Map) void {
        self.env_map.deinit();
        self.env_map = env_map;
    }

    pub fn envMap(self: *ExecBuilder) *std.process.Environ.Map {
        return &self.env_map;
    }

    pub const PipeExecError = Allocator.Error || error{
        CircleDependency,
    };

    pub fn pipeExec(self: *ExecBuilder, output: Source.ExecSource.Output, to: *ExecBuilder) PipeExecError!void {
        if (self.dependsOn(to.idx)) {
            return PipeExecError.CircleDependency;
        }

        const source = try to.stdin.addOne(to.ctx.allocator);
        errdefer _ = to.stdin.pop();
        source.* = .{ .execution = .{
            .idx = self.idx,
            .output = output,
        } };

        if (output.stdout) {
            const sink = try self.stdout.addOne(to.ctx.allocator);
            errdefer _ = self.stdout.pop();
            sink.* = .{ .execution = to.idx };
        }

        if (output.stderr) {
            const sink = try self.stderr.addOne(to.ctx.allocator);
            errdefer _ = self.stderr.pop();
            sink.* = .{ .execution = to.idx };
        }
    }

    pub const FromFileError = Allocator.Error || GetOrCreateFileIdxError;

    pub fn pipeFromFile(self: *ExecBuilder, io: std.Io, path: []const u8) FromFileError!void {
        const file_idx = try self.ctx.getOrCreateFileIdx(io, path);
        const tracked_file = self.ctx.getFile(file_idx);
        errdefer self.ctx.cleanFile(file_idx);

        const source = try self.stdin.addOne(self.ctx.allocator);
        errdefer _ = self.stdin.pop();
        source.* = .{ .file = .{
            .idx = file_idx,
            .accessor = tracked_file.accessed,
        } };
        tracked_file.accessed += 1;
        errdefer tracked_file.accessed -= 1;
    }

    pub const ToFileError = Allocator.Error || GetOrCreateFileIdxError;

    pub fn pipeFile(self: *ExecBuilder, io: std.Io, output: Sink.FileSink.Output, path: []const u8) ToFileError!void {
        const file_idx = try self.ctx.getOrCreateFileIdx(io, path);
        const tracked_file = self.ctx.getFile(file_idx);
        errdefer self.ctx.cleanFile(file_idx);

        if (output.stdout) |mode| {
            const sink = try self.stdout.addOne(self.ctx.allocator);
            errdefer _ = self.stdout.pop();
            sink.* = .{ .file = .{
                .idx = file_idx,
                .accessor = tracked_file.accessed,
                .mode = mode,
            } };

            tracked_file.accessed += 1;
            errdefer tracked_file.accessed -= 1;
        }

        if (output.stderr) |mode| {
            const sink = try self.stderr.addOne(self.ctx.allocator);
            errdefer _ = self.stder.pop();
            sink.* = .{ .file = .{
                .idx = file_idx,
                .accessor = tracked_file.accessed,
                .mode = mode,
            } };

            tracked_file.accessed += 1;
            errdefer tracked_file.accessed -= 1;
        }
    }

    pub const DependsOnError = Allocator.Error || error{
        CircleDependency,
    };

    pub fn dependOn(self: *ExecBuilder, other: *const ExecBuilder) DependsOnError!void {
        if (self.idx == other.idx) {
            return;
        }

        if (other.dependsOn(self.idx)) {
            return DependsOnError.CircleDependency;
        }

        try self.depends_on.append(self.ctx.allocator, other.idx);
        errdefer _ = self.depends_on.pop();
    }

    const Source = union(enum) {
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

    const Sink = union(enum) {
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
};

const TrackedFile = struct {
    path: []const u8,
    accessed: u32 = 0,

    fn init(allocator: std.mem.Allocator, path: []const u8) Allocator.Error!TrackedFile {
        const copy_path = try allocator.dupe(u8, path);
        errdefer allocator.free(copy_path);

        return TrackedFile{
            .path = copy_path,
        };
    }

    fn deinit(self: *TrackedFile, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

test "cricle dependency" {
    var zlush = try Zlush.init(testing.allocator, null, .{
        .load_profile = false,
    });
    defer zlush.deinit();

    var ctx = try zlush.context(testing.allocator);
    defer ctx.deinit();

    const a = try ctx.exec(&.{"echo"});

    const b = try ctx.exec(&.{"cat"});
    try b.dependOn(a);

    try testing.expectError(ExecBuilder.DependsOnError.CircleDependency, a.dependOn(b));
}
