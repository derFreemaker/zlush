const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const IndexT = @import("index.zig").IndexT;
const Plan = @import("Plan.zig");
const FileIdx = Plan.FileIdx;
const ExecIdx = Plan.ExecIdx;
const Arg = Plan.Execution.Arg;
const Source = Plan.Source;
const Sink = Plan.Sink;
const Zlush = @import("Zlush.zig");

const ExecCtx = @This();

allocator: Allocator,

zlush: *const Zlush,

env_map: std.process.Environ.Map,
executions: std.ArrayList(ExecBuilder),
tracked_files: std.ArrayList(TrackedFile),

pub fn init(allocator: Allocator, zlush: *const Zlush) Allocator.Error!ExecCtx {
    var env_map = try zlush.env_map.clone(allocator);
    errdefer env_map.deinit();

    return ExecCtx{
        .allocator = allocator,

        .zlush = zlush,

        .env_map = env_map,
        .executions = .empty,
        .tracked_files = .empty,
    };
}

pub fn deinit(self: *ExecCtx) void {
    self.env_map.deinit();

    for (self.executions.items) |*execution| {
        execution.deinit();
    }
    self.executions.deinit(self.allocator);

    for (self.tracked_files.items) |*tracked_file| {
        tracked_file.deinit(self.allocator);
    }
    self.tracked_files.deinit(self.allocator);
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

pub fn addFile(self: *ExecCtx, path: []const u8) Allocator.Error!FileIdx {
    const idx = FileIdx.fromAny(self.tracked_files.items.len) catch return Allocator.Error.OutOfMemory;

    const tracked_file = try self.tracked_files.addOne(self.allocator);
    errdefer _ = self.tracked_files.pop();
    tracked_file.* = try TrackedFile.init(self.allocator, path);
    errdefer tracked_file.deinit(self.allocator);

    return idx;
}

pub fn getFile(self: *const ExecCtx, file_idx: FileIdx) *TrackedFile {
    return &self.tracked_files.items[file_idx.value()];
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

    const idx = ExecIdx.fromAny(self.executions.items.len) catch return ExecCreationError.OutOfMemory;
    const execution = try self.executions.addOne(self.allocator);
    errdefer _ = self.executions.pop();

    execution.* = try ExecBuilder.init(idx, self, args);
    return execution;
}

pub fn getExec(self: *const ExecCtx, idx: ExecIdx) *ExecBuilder {
    return &self.executions.items[idx.value()];
}

pub fn plan(self: *const ExecCtx, allocator: std.mem.Allocator) Allocator.Error!Plan {
    var env_map = try self.env_map.clone(allocator);
    errdefer env_map.deinit();

    var executions = try std.ArrayList(Plan.Execution).initCapacity(allocator, self.executions.items.len);
    errdefer {
        for (executions.items) |*execution| {
            execution.deinit(allocator);
        }
        executions.deinit(allocator);
    }
    for (self.executions.items) |exec_builder| {
        var args = try std.ArrayList(Arg).initCapacity(allocator, exec_builder.args.items.len);
        errdefer {
            for (args.items) |*arg| {
                arg.deinit(allocator);
            }
            args.deinit(allocator);
        }
        for (exec_builder.args.items) |arg| {
            args.appendAssumeCapacity(switch (arg) {
                .str => |str| .{ .str = try allocator.dupe(u8, str) },
                .exec => |exec_arg| .{ .exec = exec_arg },
            });
        }

        var execution_env_map = try exec_builder.env_map.clone(allocator);
        errdefer execution_env_map.deinit();

        var stdin = try exec_builder.stdin.clone(allocator);
        errdefer stdin.deinit(allocator);

        var stdout = try exec_builder.stdout.clone(allocator);
        errdefer stdout.deinit(allocator);

        var stderr = try exec_builder.stderr.clone(allocator);
        errdefer stderr.deinit(allocator);

        var depends_on = try exec_builder.depends_on.clone(allocator);
        errdefer depends_on.deinit(allocator);

        executions.appendAssumeCapacity(Plan.Execution{
            .args = args,
            .env_map = execution_env_map,

            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,

            .depends_on = depends_on,
        });
    }

    var tracked_files = try std.ArrayList(Plan.TrackedFile).initCapacity(allocator, self.tracked_files.items.len);
    errdefer {
        for (tracked_files.items) |*tracked_file| {
            tracked_file.deinit(allocator);
        }
        tracked_files.deinit(allocator);
    }
    for (self.tracked_files.items) |tracked_file| {
        const path = try allocator.dupe(u8, tracked_file.path);

        tracked_files.appendAssumeCapacity(Plan.TrackedFile{
            .path = path,
        });
    }

    return Plan{
        .allocator = allocator,

        .env_map = env_map,
        .executions = executions,
        .tracked_files = tracked_files,
    };
}

pub const ExecBuilder = struct {
    idx: ExecIdx,
    ctx: *ExecCtx,

    args: std.ArrayList(Arg),
    env_map: std.process.Environ.Map,
    // @TODO: add current_working_directory

    stdin: std.ArrayList(Source),
    stdout: std.ArrayList(Sink),
    stderr: std.ArrayList(Sink),
    // @TODO: collect stdout/stderr

    depends_on: std.ArrayList(ExecIdx),

    fn init(idx: ExecIdx, ctx: *ExecCtx, args_slice: []const []const u8) Allocator.Error!ExecBuilder {
        var args: std.ArrayList(Arg) = try .initCapacity(ctx.allocator, args_slice.len);
        errdefer {
            for (args.items) |*arg| {
                arg.deinit(ctx.allocator);
            }
            args.deinit(ctx.allocator);
        }
        for (args_slice) |arg| {
            args.appendAssumeCapacity(.{ .str = try ctx.allocator.dupe(u8, arg) });
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
        for (self.args.items) |*arg| {
            arg.deinit(self.ctx.allocator);
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

        // @TODO: maybe add some kind of cache to avoid checking the same execution again and again.

        for (self.args.items) |arg| {
            switch (arg) {
                else => {},
                .exec => |exec_arg| {
                    if (exec_arg.idx == other) {
                        return true;
                    }

                    const execution = self.ctx.getExec(exec_arg.idx);
                    if (execution.dependsOn(other)) {
                        return true;
                    }
                },
            }
        }

        for (self.stdin.items) |source| {
            switch (source) {
                else => {},
                .exec => |exec_source| {
                    if (exec_source.idx == other) {
                        return true;
                    }

                    const execution = self.ctx.getExec(exec_source.idx);
                    if (execution.dependsOn(other)) {
                        return true;
                    }
                },
            }
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
            args_slice[arg_i] = Arg{ .str = try self.ctx.allocator.dupe(u8, arg) };
            arg_i += 1;
        }
    }

    pub const ExecOutputAsArgError = Allocator.Error || error{
        CircleDependency,
    };

    pub fn addExecOutputAsArg(self: *ExecBuilder, from: *ExecBuilder, output: Source.ExecSource.Output) ExecOutputAsArgError!void {
        if (self.dependsOn(from.idx)) {
            return ExecOutputAsArgError.CircleDependency;
        }

        try self.args.append(self.ctx.allocator, .{ .exec = .{
            .idx = from.idx,
            .output = output,
        } });
        errdefer _ = self.args.pop();
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

    pub fn pipeExec(self: *ExecBuilder, output: Plan.Source.ExecSource.Output, to: *ExecBuilder) PipeExecError!void {
        if (self.dependsOn(to.idx)) {
            return PipeExecError.CircleDependency;
        }

        const source = try to.stdin.addOne(to.ctx.allocator);
        errdefer _ = to.stdin.pop();
        source.* = .{ .exec = .{
            .idx = self.idx,
            .output = output,
        } };

        if (output.stdout) {
            const sink = try self.stdout.addOne(to.ctx.allocator);
            errdefer _ = self.stdout.pop();
            sink.* = .{ .exec = to.idx };
        }

        if (output.stderr) {
            const sink = try self.stderr.addOne(to.ctx.allocator);
            errdefer _ = self.stderr.pop();
            sink.* = .{ .exec = to.idx };
        }
    }

    pub fn pipeFromFile(self: *ExecBuilder, file_idx: FileIdx) Allocator.Error!void {
        const tracked_file = self.ctx.getFile(file_idx);

        const source = try self.stdin.addOne(self.ctx.allocator);
        errdefer _ = self.stdin.pop();
        source.* = .{ .file = .{
            .idx = file_idx,
            .accessor = tracked_file.accessed,
        } };
        tracked_file.accessed += 1;
        errdefer tracked_file.accessed -= 1;
    }

    pub fn pipeToFile(self: *ExecBuilder, output: Plan.Sink.FileSink.Output, file_idx: FileIdx) Allocator.Error!void {
        const tracked_file = self.ctx.getFile(file_idx);

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
};

const TrackedFile = struct {
    path: []const u8,
    accessed: u32 = 0,

    fn init(allocator: std.mem.Allocator, path: []const u8) Allocator.Error!TrackedFile {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        return TrackedFile{
            .path = path_copy,
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
    try b.addExecOutputAsArg(a, .{});

    try testing.expectError(ExecBuilder.DependsOnError.CircleDependency, a.dependOn(b));
}
