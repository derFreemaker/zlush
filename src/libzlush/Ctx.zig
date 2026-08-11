const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Pl = @import("Plan.zig");
const StableList = @import("stable_list.zig").StableList;

const NodeList = StableList(Node, Pl.NodeIdx.UnderlyingT);
const NodeIdx = NodeList.Index;
const EdgeList = StableList(Edge, Pl.EdgeIdx.UnderlyingT);
const EdgeIdx = EdgeList.Index;

const Ctx = @This();

allocator: Allocator,

nodes: NodeList,
edges: EdgeList,

pub fn init(allocator: Allocator) Ctx {
    return Ctx{
        .allocator = allocator,

        .nodes = .empty,
        .edges = .empty,
    };
}

pub fn deinit(self: *Ctx) void {
    for (self.nodes.data.items) |*node| {
        node.deinit(self.allocator);
    }
    self.nodes.deinit(self.allocator);

    self.edges.deinit(self.allocator);
}

pub fn dependsOn(self: *const Ctx, a: NodeIdx, b: NodeIdx) bool {
    if (a == b) {
        return false;
    }

    const node = self.nodes.get(a);
    for (node.depends_on.items) |dep| {
        if (dep.idx == b) {
            return true;
        }

        if (self.dependsOn(dep.idx, b)) {
            return true;
        }
    }

    return false;
}

pub const DependOnError = Allocator.Error || error{
    CircleDependency,
};

fn dependOn(self: *Ctx, a: NodeIdx, b: NodeIdx, kind: Pl.Dependency.Kind) DependOnError!DependencyResult {
    if (self.dependsOn(b, a)) {
        return DependOnError.CircleDependency;
    }

    const node = self.nodes.get(a);
    for (node.depends_on.items, 0..) |*dep, i| {
        if (dep.idx == b) {
            const result = DependencyResult{
                .node = a,
                .idx = i,
                .previous = dep.kind,
            };

            if (dep.kind == .implicit) {
                dep.kind = kind;
            }

            return result;
        }
    }

    const result = DependencyResult{
        .node = a,
        .idx = node.depends_on.items.len,
        .previous = null,
    };

    try node.depends_on.append(self.allocator, Dependency{
        .idx = b,
        .kind = kind,
    });
    errdefer _ = node.depends_on.pop();

    return result;
}

pub fn registerFile(self: *Ctx, path: []const u8) Allocator.Error!FileIdx {
    const copy = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(copy);

    const node_idx = try self.nodes.append(self.allocator, Node{
        .data = .{ .file = .{
            .path = copy,
        } },
    });
    errdefer _ = self.nodes.pop();

    return FileIdx{
        .idx = node_idx,
    };
}

pub const ExecCreationError = Allocator.Error || error{
    NoArgProvided,
};

pub fn exec(self: *Ctx, args: []const []const u8, env_map: ?*const std.process.Environ.Map) ExecCreationError!ExecBuilder {
    if (args.len == 0) {
        return ExecCreationError.NoArgProvided;
    }

    return try ExecBuilder.init(self, args, env_map);
}

pub fn plan(self: *const Ctx, allocator: Allocator) Allocator.Error!Pl {
    _ = self; // autofix
    _ = allocator; // autofix
    @panic("unimplemented");
}

pub const ExecBuilder = struct {
    ctx: *Ctx,
    idx: NodeIdx,

    fn init(ctx: *Ctx, args: []const []const u8, env_map: ?*const std.process.Environ.Map) Allocator.Error!ExecBuilder {
        const idx = try ctx.nodes.append(ctx.allocator, Node{
            .data = .{ .exec = .{
                .env = .init(ctx.allocator),
            } },
        });
        errdefer ctx.nodes.pop();

        const builder = ExecBuilder{
            .ctx = ctx,
            .idx = idx,
        };
        const data = builder.getData();

        data.env = if (env_map) |env| try env.clone(ctx.allocator) else std.process.Environ.Map.init(ctx.allocator);
        errdefer data.env.deinit();

        data.args = try .initCapacity(ctx.allocator, args.len);
        errdefer {
            for (data.args.items) |*arg| {
                arg.deinit(ctx.allocator);
            }
            data.args.deinit(ctx.allocator);
        }
        for (args) |arg| {
            data.args.appendAssumeCapacity(.{ .literal = try ctx.allocator.dupe(u8, arg) });
        }

        return builder;
    }

    fn get(self: *const ExecBuilder) *Node {
        return self.ctx.nodes.get(self.idx);
    }

    fn getData(self: *const ExecBuilder) *Node.Data.Execution {
        return &self.get().data.exec;
    }

    pub inline fn dependOn(self: *const ExecBuilder, other: NodeIdx) DependOnError!DependencyResult {
        return self.ctx.dependOn(self.idx, other, .explicit);
    }

    pub fn addArgs(self: *const ExecBuilder, args: []const []const u8) Allocator.Error!void {
        const ArgSlot = Node.Data.Execution.ArgSlot;

        const data = self.getData();

        const args_slice = try data.args.addManyAsSlice(self.ctx.allocator, args.len);
        errdefer self.args.items.len -= args_slice.len;

        var arg_i: usize = 0;
        errdefer for (0..arg_i) |i| {
            const arg = &args_slice[i];
            arg.deinit(self.ctx.allocator);
        };
        for (args) |arg| {
            args_slice[arg_i] = ArgSlot{ .literal = try self.ctx.allocator.dupe(u8, arg) };
            arg_i += 1;
        }
    }

    pub const ExecOutputAsArgError = Allocator.Error || DependOnError;

    pub fn addExecOutputAsArg(self: *const ExecBuilder, from: *const ExecBuilder, config: AddExecOutputAsArgConfig) ExecOutputAsArgError!void {
        const dep = try self.ctx.dependOn(self.idx, from.idx, .implicit);
        errdefer dep.deinit(self.ctx);

        const data = self.getData();

        const edge_idx = try self.ctx.edges.append(self.ctx.allocator, Edge{
            .source = from.idx,
            .target = self.idx,
            .source_data = .{ .exec = .{
                .output = config.output,
            } },
            .target_data = .{ .exec = .{
                .role = .{ .arg = .{
                    .idx = data.args.items.len,
                    .trim = config.trim,
                } },
            } },
        });
        errdefer self.ctx.edges.pop();

        try data.args.append(self.ctx.allocator, Pl.Node.Data.Execution.ArgSlot{
            .captured = edge_idx,
        });
        errdefer _ = data.args.pop();
    }

    pub const AddExecOutputAsArgConfig = struct {
        output: Pl.Edge.SourceData.Execution.Output = .{
            .stdout = true,
            .stderr = false,
        },
        trim: Pl.Edge.TargetData.Execution.Role.Arg.Trim = .trim_newlines,
    };

    pub fn setEnvMap(self: *const ExecBuilder, env_map: std.process.Environ.Map) Allocator.Error!void {
        const clone = try env_map.clone(self.ctx.allocator);
        return self.setEnvMapMove(clone);
    }

    /// takes ownership of `env_map`
    pub fn setEnvMapMove(self: *const ExecBuilder, env_map: std.process.Environ.Map) void {
        const data = self.getData();
        data.env.deinit();
        data.env = env_map;
    }

    pub fn envMap(self: *const ExecBuilder) *std.process.Environ.Map {
        return &self.getData().env;
    }

    // @TODO: rewise piping api

    pub const PipeError = Allocator.Error || DependOnError;

    pub fn pipe(self: *const ExecBuilder, config: PipeConfig) PipeError!void {
        const ctx = self.ctx;

        const dep = try ctx.dependOn(config.to.idx, self.idx, .implicit);
        errdefer dep.deinit(ctx);

        const to_node = ctx.nodes.get(config.to);
        const target_data = switch (to_node.data) {
            .exec => Pl.Edge.TargetData{ .exec = .{
                .role = .stdin,
            } },
            .file => Pl.Edge.TargetData{ .file = .{
                .mode = .append,
            } },
        };

        const edge_idx = try ctx.edges.append(ctx.allocator, Edge{
            .source = self.idx,
            .target = config.to,
            .source_data = .{ .exec = .{
                .output = config.output,
            } },
            .target_data = target_data,
        });
        errdefer ctx.edges.pop();

        try to_node.sources.append(ctx.allocator, edge_idx);
        errdefer _ = to_node.sources.pop();

        const node = self.get();
        try node.sinks.append(ctx.allocator, edge_idx);
        errdefer _ = node.sinks.pop();
    }

    pub const PipeConfig = struct {
        to: NodeIdx,
        output: Pl.Edge.SourceData.Execution.Output = .{
            .stdout = true,
            .stderr = false,
        },
    };

    pub fn pipeFile(self: *const ExecBuilder, output: Pl.Edge.SourceData.Execution.Output, to: FileIdx, config: PipeFileConfig) PipeError!void {
        const ctx = self.ctx;

        const dep = try ctx.dependOn(to.idx, self.idx, .implicit);
        errdefer dep.deinit(ctx);

        const to_node = ctx.nodes.get(to);
        const target_data = switch (to_node.data) {
            .exec => Pl.Edge.TargetData{ .exec = .{
                .role = .stdin,
            } },
            .file => Pl.Edge.TargetData{ .file = .{
                .mode = config.mode,
                .path = config.path,
            } },
        };

        const edge_idx = try ctx.edges.append(ctx.allocator, Edge{
            .source = self.idx,
            .target = to,
            .source_data = .{ .exec = .{
                .output = output,
            } },
            .target_data = target_data,
        });
        errdefer ctx.edges.pop();

        try to_node.sources.append(ctx.allocator, edge_idx);
        errdefer _ = to_node.sources.pop();

        const node = self.get();
        try node.sinks.append(ctx.allocator, edge_idx);
        errdefer _ = node.sinks.pop();
    }

    pub const PipeFileConfig = struct {
        mode: Pl.Edge.TargetData.File.WriteMode = .append,
        path: ?[]const u8 = null,
    };
};

pub const FileIdx = struct {
    idx: NodeIdx,

    pub inline fn dependOn(self: FileIdx, other: *const ExecBuilder) DependOnError!void {
        return other.ctx.dependOn(self.idx, other, .explicit);
    }

    pub fn pipe(self: FileIdx, to: *const ExecBuilder, config: PipeFileConfig) ExecBuilder.PipeError!void {
        const ctx = to.ctx;

        const dep = try ctx.dependOn(to.idx, self.idx, .implicit);
        errdefer dep.deinit(ctx);

        const to_node = to.get();
        const edge_idx = try ctx.edges.append(ctx.allocator, Edge{
            .source = self.idx,
            .target = to.idx,
            .source_data = .{ .file = .{
                .path = config.path,
            } },
            .target_data = .{ .exec = .{
                .role = .stdin,
            } },
        });
        errdefer ctx.edges.pop();

        try to_node.sources.append(ctx.allocator, edge_idx);
        errdefer _ = to_node.sources.pop();

        const node = to.get();
        try node.sinks.append(ctx.allocator, edge_idx);
        errdefer _ = node.sinks.pop();
    }

    pub const PipeFileConfig = struct {
        path: ?[]const u8 = null,
    };
};

const Node = struct {
    data: Data,

    sources: std.ArrayList(EdgeIdx) = .empty,
    sinks: std.ArrayList(EdgeIdx) = .empty,

    depends_on: std.ArrayList(Dependency) = .empty,

    pub fn deinit(self: *Node, allocator: Allocator) void {
        self.data.deinit(allocator);

        self.sources.deinit(allocator);
        self.sinks.deinit(allocator);

        self.depends_on.deinit(allocator);
    }

    const Data = union(enum) {
        exec: Execution,
        file: File,

        pub fn deinit(self: *Data, allocator: Allocator) void {
            switch (self.*) {
                .exec => self.exec.deinit(allocator),
                .file => self.file.deinit(allocator),
            }
        }

        const Execution = struct {
            args: std.ArrayList(Pl.Node.Data.Execution.ArgSlot) = .empty,
            env: std.process.Environ.Map,

            collect_stdout: bool = false,
            collect_stderr: bool = false,

            pub fn deinit(self: *Execution, allocator: Allocator) void {
                for (self.args.items) |*arg| {
                    arg.deinit(allocator);
                }
                self.args.deinit(allocator);

                self.env.deinit();
            }
        };

        const File = struct {
            path: []const u8,

            pub fn deinit(self: *File, allocator: Allocator) void {
                allocator.free(self.path);
            }
        };
    };
};

const Edge = struct {
    source: NodeIdx,
    target: NodeIdx,
    source_data: Pl.Edge.SourceData,
    target_data: Pl.Edge.TargetData,
};

const Dependency = struct {
    idx: NodeIdx,
    kind: Pl.Dependency.Kind,
};

const DependencyResult = struct {
    node: NodeIdx,
    idx: usize,
    previous: ?Pl.Dependency.Kind,

    pub fn gotAdded(self: DependencyResult) bool {
        return self.previous == null;
    }

    pub fn deinit(self: DependencyResult, ctx: *Ctx) void {
        const node = ctx.nodes.get(self.node);

        if (self.gotAdded()) {
            _ = node.depends_on.orderedRemove(self.idx);
        } else {
            node.depends_on.items[self.idx].kind = self.previous.?;
        }
    }
};

test "cricle dependency" {
    var ctx = Ctx.init(testing.allocator);
    defer ctx.deinit();

    const a = try ctx.exec(&.{"echo"}, null);

    const b = try ctx.exec(&.{"cat"}, null);
    try b.addExecOutputAsArg(&a, .{});

    try testing.expectError(DependOnError.CircleDependency, a.dependOn(b.idx));
}
