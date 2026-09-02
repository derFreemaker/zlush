const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const StableList = @import("common/StableList.zig").StableList;
const Pl = @import("Plan.zig");
const Zlush = @import("Zlush.zig");

const NodeList = StableList(Node, Pl.NodeIdx.UnderlyingT);
const NodeIdx = NodeList.Index;
const SourceList = StableList(Source, Pl.SourceIdx.UnderlyingT);
const SourceIdx = SourceList.Index;
const SinkList = StableList(Sink, Pl.SinkIdx.UnderlyingT);
const SinkIdx = SinkList.Index;
const EdgeList = StableList(Edge, Pl.EdgeIdx.UnderlyingT);
const EdgeIdx = EdgeList.Index;
const DepList = StableList(Dependency, Pl.DepIdx.UnderlyingT);
const DepIdx = DepList.Index;
const NodeDepList = StableList(DepIdx, Pl.DepIdx.UnderlyingT);
const NodeDepIdx = NodeDepList.Index;

const Ctx = @This();

gpa: Allocator,

// CLEANUP(freemaker): make own config section for execution
config: *const Zlush.Config,

nodes: NodeList,

// @TODO: rework hash map situation

sources: SourceList,
source_map: std.HashMapUnmanaged(SourceKey, SourceIdx, SourceHashContext, 80),

sinks: SinkList,
sink_map: std.HashMapUnmanaged(SinkKey, SinkIdx, SinkHashContext, 80),

edges: EdgeList,
dependencies: DepList,

pub fn init(self: *Ctx, gpa: Allocator, config: *const Zlush.Config) Allocator.Error!void {
    self.gpa = gpa;
    self.config = config;

    try NodeList.initCapacity(&self.nodes, gpa, 32);
    errdefer self.nodes.deinit(gpa);

    try SourceList.initCapacity(&self.sources, gpa, 32);
    errdefer self.sources.deinit(gpa);
    self.source_map = .empty;

    try SinkList.initCapacity(&self.sinks, gpa, 32);
    errdefer self.sinks.deinit(gpa);
    self.sink_map = .empty;

    try EdgeList.initCapacity(&self.edges, gpa, 32);
    errdefer self.edges.deinit(gpa);

    try DepList.initCapacity(&self.dependencies, gpa, 32);
    errdefer self.dependencies.deinit(gpa);
}

pub fn deinit(self: *Ctx) void {
    for (self.nodes.data.items) |*node| {
        node.deinit(self.gpa);
    }
    self.nodes.deinit(self.gpa);

    self.source_map.deinit(self.gpa);
    for (self.sources.data.items) |*source| {
        source.deinit(self.gpa);
    }
    self.sources.deinit(self.gpa);

    self.sink_map.deinit(self.gpa);
    for (self.sinks.data.items) |*sink| {
        sink.deinit(self.gpa);
    }
    self.sinks.deinit(self.gpa);

    self.edges.deinit(self.gpa);
    self.dependencies.deinit(self.gpa);
}

pub fn dependsOn(self: *const Ctx, a: NodeIdx, b: NodeIdx) bool {
    if (a == b) {
        return false;
    }

    const node = self.nodes.get(a);
    for (node.dep_on.data.items) |dep_idx| {
        const dep = self.dependencies.get(dep_idx);
        if (dep.target == b) {
            return true;
        }

        if (self.dependsOn(dep.target, b)) {
            return true;
        }
    }

    return false;
}

pub const DependOnError = Allocator.Error || error{
    CircleDependency,
};

fn dependOn(self: *Ctx, a: NodeIdx, b: NodeIdx, wait_mode: Pl.Dependency.WaitMode, kind: Pl.Dependency.Kind) DependOnError!DependencyResult {
    if (self.dependsOn(b, a)) {
        return DependOnError.CircleDependency;
    }

    const node = self.nodes.get(a);
    for (node.dep_on.data.items) |dep_idx| {
        const dep = self.dependencies.get(dep_idx);
        if (dep.target == b) {
            const result = DependencyResult{
                .idx = dep_idx,
                .node_idx = dep.node,

                .previous_wait_mode = dep.wait_mode,
                .previous_kind = dep.kind,
            };

            if (dep.kind == .implicit) {
                dep.kind = kind;
            }

            if (dep.wait_mode == .started) {
                dep.wait_mode = wait_mode;
            }

            return result;
        }
    }

    const dep_idx = try self.dependencies.append(self.gpa, Dependency{
        .node = a,
        .target = b,

        .wait_mode = wait_mode,
        .kind = kind,
    });
    errdefer self.dependencies.remove(dep_idx);

    const node_dep_idx = try node.dep_on.append(self.gpa, dep_idx);
    errdefer _ = node.dep_on.pop();

    const target_node = self.nodes.get(b);
    const target_dep_idx = try target_node.dep_of.append(self.gpa, dep_idx);
    errdefer _ = target_node.dep_of.pop();

    return DependencyResult{
        .idx = dep_idx,
        .node_idx = node_dep_idx,
        .target_idx = target_dep_idx,

        .previous_wait_mode = null,
        .previous_kind = null,
    };
}

fn getOrCreateSource(self: *Ctx, key: SourceKey) Allocator.Error!SourceResult {
    const result = try self.source_map.getOrPut(self.gpa, key);
    errdefer if (!result.found_existing) {
        _ = self.source_map.remove(key);
    };
    if (result.found_existing) {
        return SourceResult{
            .key = key,
            .idx = result.value_ptr.*,
            .created = false,
        };
    }

    const idx = try self.sources.append(self.gpa, Source{
        .node = key.node,
        .data = switch (key.data) {
            .exec => |execution| .{ .exec = execution },
            .file => |file| blk: {
                const path = if (file.path) |path| try self.gpa.dupe(u8, path) else null;
                errdefer if (path) |p| self.gpa.free(p);

                break :blk .{ .file = .{
                    .path = path,
                } };
            },
        },
    });
    errdefer {
        const source = self.sources.get(idx);
        source.deinit(self.gpa);
        self.sources.remove(idx);
    }

    result.value_ptr.* = idx;
    return SourceResult{
        .key = key,
        .idx = idx,
        .created = true,
    };
}

pub const SourceResult = struct {
    key: SourceKey,
    idx: SourceIdx,
    created: bool,

    pub fn deinit(self: *const SourceResult, ctx: *Ctx) void {
        if (!self.created) {
            return;
        }

        _ = ctx.source_map.remove(self.key);

        const source = ctx.sources.get(self.idx);
        source.deinit(ctx.gpa);
        ctx.sources.remove(self.idx);
    }
};

fn getOrCreateSink(self: *Ctx, key: SinkKey) Allocator.Error!SinkResult {
    const result = try self.sink_map.getOrPut(self.gpa, key);
    errdefer if (!result.found_existing) {
        _ = self.sink_map.remove(key);
    };
    if (result.found_existing) {
        return SinkResult{
            .key = key,
            .idx = result.value_ptr.*,
            .created = false,
        };
    }

    const idx = try self.sinks.append(self.gpa, Sink{
        .node = key.node,
        .data = switch (key.data) {
            .exec => |execution| .{ .exec = execution },
            .file => |file| blk: {
                const path = if (file.path) |path| try self.gpa.dupe(u8, path) else null;
                errdefer if (path) |p| self.gpa.free(p);

                break :blk .{ .file = .{
                    .path = path,
                } };
            },
        },
    });
    errdefer {
        const sink = self.sinks.get(idx);
        sink.deinit(self.gpa);
        self.sinks.pop();
    }

    result.value_ptr.* = idx;
    return SinkResult{
        .key = key,
        .idx = idx,
        .created = true,
    };
}

pub const SinkResult = struct {
    key: SinkKey,
    idx: SinkIdx,
    created: bool,

    pub fn deinit(self: *const SinkResult, ctx: *Ctx) void {
        if (!self.created) {
            return;
        }

        _ = ctx.sink_map.remove(self.key);

        const sink = ctx.sinks.get(self.idx);
        defer ctx.sinks.pop();
        sink.deinit(ctx.gpa);
    }
};

fn addEdge(self: *Ctx, source_key: SourceKey, sink_key: SinkKey) Allocator.Error!EdgeResult {
    const source_result = try self.getOrCreateSource(source_key);
    errdefer source_result.deinit(self);

    const sink_result = try self.getOrCreateSink(sink_key);
    errdefer sink_result.deinit(self);

    const idx = try self.edges.append(self.gpa, Edge{
        .source = source_result.idx,
        .sink = sink_result.idx,
    });
    errdefer self.edges.pop();

    const source_node = self.nodes.get(source_key.node);
    try source_node.sinks.append(self.gpa, idx);
    errdefer _ = source_node.sinks.pop();

    const sink_node = self.nodes.get(sink_key.node);
    try sink_node.sources.append(self.gpa, idx);
    errdefer _ = sink_node.sources.pop();

    const source = self.sources.get(source_result.idx);
    source.sinks_count += 1;
    errdefer source.sinks_count -= 1;

    return EdgeResult{
        .idx = idx,
        .source_result = source_result,
        .sink_result = sink_result,
    };
}

pub const EdgeResult = struct {
    idx: EdgeIdx,
    source_result: SourceResult,
    sink_result: SinkResult,

    pub fn deinit(self: *const EdgeResult, ctx: *Ctx) void {
        ctx.edges.pop();

        const source = ctx.sources.get(self.source_result.idx);
        source.sinks_count -= 1;
        self.source_result.deinit(ctx);
        const source_node = ctx.nodes.get(self.source_result.key.node);
        _ = source_node.sinks.pop();

        self.sink_result.deinit(ctx);
        const sink_node = ctx.nodes.get(self.sink_result.key.node);
        _ = sink_node.sources.pop();
    }
};

pub fn registerFile(self: *Ctx, path: []const u8) Allocator.Error!FileIdx {
    const copy = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(copy);

    const node_idx = try self.nodes.append(self.gpa, Node{
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

// pub fn plan(self: *const Ctx, allocator: Allocator) Allocator.Error!Pl {
//     var node_i: usize = 0;
//     const nodes = try allocator.alloc(Pl.Node, self.nodes.data.items.len);
//     errdefer {
//         for (nodes[0..node_i]) |*node| {
//             node.deinit(allocator);
//         }
//         allocator.free(nodes);
//     }
//     for (self.nodes.data.items) |node| {
//         const copy = &nodes[node_i];

//         switch (node.data) {
//             .exec => |execution| {
//                 const ArgSlot = Pl.Node.Data.Execution.ArgSlot;

//                 var arg_i: usize = 0;
//                 const args = try allocator.alloc(ArgSlot, execution.args.items.len);
//                 errdefer {
//                     for (args[0..arg_i]) |*arg| {
//                         arg.deinit(allocator);
//                     }
//                     allocator.free(args);
//                 }
//                 for (execution.args.items) |arg| {
//                     switch (arg) {
//                         .literal => |literal| args[arg_i] = ArgSlot{
//                             .literal = try allocator.dupe(u8, literal),
//                         },

//                         .captured => |captured| args[arg_i] = ArgSlot{ .captured = Pl.EdgeIdx.from(captured.value()) },

//                         .start_concat,
//                         .end_concat,
//                         => args[arg_i] = arg,
//                     }

//                     arg_i += 1;
//                 }

//                 var env = try execution.env.clone(allocator);
//                 errdefer env.deinit();

//                 copy.data = .{ .exec = .{
//                     .args = args,
//                     .env = env,
//                     .collect_stdout = execution.collect_stdout,
//                     .collect_stderr = execution.collect_stderr,
//                 } };
//             },
//             .file => |file| {
//                 const path = try allocator.dupe(u8, file.path);
//                 errdefer allocator.free(path);

//                 copy.data = .{ .file = .{
//                     .path = path,
//                 } };
//             },
//         }
//         errdefer copy.data.deinit(allocator);

//         copy.sources = try allocator.alloc(Pl.EdgeIdx, node.sources.items.len);
//         errdefer allocator.free(copy.sources);
//         for (node.sources.items, 0..) |source, i| {
//             copy.sources[i] = Pl.EdgeIdx.from(source.value());
//         }

//         copy.sinks = try allocator.alloc(Pl.EdgeIdx, node.sinks.items.len);
//         errdefer allocator.free(copy.sinks);
//         for (node.sinks.items, 0..) |sink, i| {
//             copy.sinks[i] = Pl.EdgeIdx.from(sink.value());
//         }

//         copy.depends_on = try allocator.alloc(Pl.Dependency, node.depends_on.items.len);
//         errdefer allocator.free(copy.depends_on);
//         for (node.depends_on.items, 0..) |dep, i| {
//             copy.depends_on[i] = Pl.Dependency{
//                 .idx = Pl.EdgeIdx.from(dep.idx.value()),
//                 .kind = dep.kind,
//             };
//         }

//         node_i += 1;
//     }

//     var edge_i: usize = 0;
//     const edges = try allocator.alloc(Pl.Edge, self.edges.data.items.len);
//     errdefer {
//         for (edges[0..edge_i]) |*edge| {
//             edge.deinit(allocator);
//         }
//         allocator.free(edges);
//     }
//     for (self.edges.data.items) |edge| {
//         const copy = &edges[edge_i];

//         copy.source = Pl.NodeIdx.from(edge.source.value());
//         copy.target = Pl.NodeIdx.from(edge.target.value());

//         switch (edge.source_data) {
//             .exec => |execution| {
//                 copy.source_data = .{ .exec = .{
//                     .output = execution.output,
//                 } };
//             },
//             .file => |file| {
//                 const path = if (file.path) |path| try allocator.dupe(u8, path) else null;
//                 errdefer if (path) |p| allocator.free(p);

//                 copy.source_data = .{ .file = .{
//                     .path = path,
//                 } };
//             },
//         }
//         errdefer copy.source_data.deinit(allocator);

//         switch (edge.target_data) {
//             .exec => |execution| {
//                 const role: Pl.Edge.TargetData.Execution.Role = switch (execution.role) {
//                     .stdin => .stdin,
//                     .arg => |arg| .{ .arg = .{
//                         .idx = arg.idx,
//                         .trim = arg.trim,
//                     } },
//                 };

//                 copy.target_data = .{ .exec = .{
//                     .role = role,
//                 } };
//             },
//             .file => |file| {
//                 const path = if (file.path) |path| try allocator.dupe(u8, path) else null;
//                 errdefer if (path) |p| allocator.free(p);

//                 copy.target_data = .{ .file = .{
//                     .mode = file.mode,
//                     .path = path,
//                 } };
//             },
//         }
//         errdefer copy.target_data.deinit(allocator);

//         edge_i += 1;
//     }

//     return Pl{
//         .nodes = nodes,
//         .edges = edges,
//     };
// }

pub const ExecBuilder = struct {
    ctx: *Ctx,
    node: NodeIdx,

    fn init(ctx: *Ctx, args: []const []const u8, env_map: ?*const std.process.Environ.Map) Allocator.Error!ExecBuilder {
        const idx = try ctx.nodes.append(ctx.gpa, Node{
            .data = .{ .exec = .{
                .env = .init(ctx.gpa),
            } },
        });
        errdefer ctx.nodes.pop();

        const builder = ExecBuilder{
            .ctx = ctx,
            .node = idx,
        };
        const data = builder.getData();

        data.env = if (env_map) |env| try env.clone(ctx.gpa) else std.process.Environ.Map.init(ctx.gpa);
        errdefer data.env.deinit();

        data.args = try .initCapacity(ctx.gpa, args.len);
        errdefer {
            for (data.args.items) |*arg| {
                arg.deinit(ctx.gpa);
            }
            data.args.deinit(ctx.gpa);
        }
        for (args) |arg| {
            data.args.appendAssumeCapacity(.{ .literal = try ctx.gpa.dupe(u8, arg) });
        }

        return builder;
    }

    fn get(self: *const ExecBuilder) *Node {
        return self.ctx.nodes.get(self.node);
    }

    fn getData(self: *const ExecBuilder) *Node.Data.Execution {
        return &self.get().data.exec;
    }

    pub inline fn dependOn(self: *const ExecBuilder, other: NodeIdx, wait_mode: Pl.Dependency.WaitMode) DependOnError!DependencyResult {
        return self.ctx.dependOn(self.node, other, wait_mode, .explicit);
    }

    pub fn addArgs(self: *const ExecBuilder, args: []const []const u8) Allocator.Error!void {
        const ArgSlot = Node.Data.Execution.ArgSlot;

        const data = self.getData();

        const args_slice = try data.args.addManyAsSlice(self.ctx.gpa, args.len);
        errdefer self.args.items.len -= args_slice.len;

        var arg_i: usize = 0;
        errdefer for (0..arg_i) |i| {
            const arg = &args_slice[i];
            arg.deinit(self.ctx.gpa);
        };
        for (args) |arg| {
            args_slice[arg_i] = ArgSlot{ .literal = try self.ctx.gpa.dupe(u8, arg) };
            arg_i += 1;
        }
    }

    pub const ExecOutputAsArgError = Allocator.Error || DependOnError;

    // pub fn addExecOutputAsArg(self: *const ExecBuilder, from: *const ExecBuilder, config: AddExecOutputAsArgConfig) ExecOutputAsArgError!void {
    //     const dep = try self.ctx.dependOn(self.idx, from.idx, .finished, .implicit);
    //     errdefer dep.deinit(self.ctx);

    //     const data = self.getData();

    //     // @TODO: redecide if using a Sink as collection point is really optimial,
    //     //     it should allow us to take advantage of the entire piping system though

    //     const sink_key = SinkKey{
    //         .node = self.idx,
    //         .data = .{ .exec = .{
    //             .role = .{ .arg = .{
    //                 .idx = data.args.items.len,
    //                 .trim = config.trim,
    //             } },
    //         } },
    //     };
    //     const sink_result = try self.ctx.getOrCreateSink(sink_key);
    //     errdefer sink_result.deinit(self.ctx);

    //     var stdout_edge_result: ?EdgeResult = null;
    //     errdefer if (stdout_edge_result) |result| result.deinit(self.ctx);
    //     if (config.stdout) {
    //         stdout_edge_result = try self.ctx.addEdge(
    //             SourceKey{
    //                 .node = from.idx,
    //                 .data = .{ .exec = .stdout },
    //             },
    //             sink_key,
    //         );

    //         // @TODO: rollback on errdefer
    //         from.collectStdout();
    //     }

    //     var stderr_edge_result: ?EdgeResult = null;
    //     errdefer if (stderr_edge_result) |result| result.deinit(self.ctx);
    //     if (config.stderr) {
    //         stderr_edge_result = try self.ctx.addEdge(
    //             SourceKey{
    //                 .node = from.idx,
    //                 .data = .{ .exec = .stderr },
    //             },
    //             sink_key,
    //         );

    //         // @TODO: rollback on errdefer
    //         from.collectStderr();
    //     }

    //     try data.args.append(self.ctx.allocator, Pl.Node.Data.Execution.ArgSlot{
    //         .captured = sink_result.idx,
    //     });
    //     errdefer _ = data.args.pop();
    // }

    pub const AddExecOutputAsArgConfig = struct {
        stdout: bool = true,
        stderr: bool = false,

        trim: Pl.Sink.Data.Execution.Role.Arg.Trim = .trim_newlines,
    };

    pub fn setEnvMap(self: *const ExecBuilder, env_map: std.process.Environ.Map) Allocator.Error!void {
        const clone = try env_map.clone(self.ctx.gpa);
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

    // @TODO: revisit piping api

    pub const PipeError = Allocator.Error || DependOnError;

    pub fn pipe(self: *const ExecBuilder, sink: NodeIdx, output: Pl.Source.Data.ExecutionOutput) PipeError!void {
        const ctx = self.ctx;

        const dep = try ctx.dependOn(sink, self.node, .started, .implicit);
        errdefer dep.deinit(ctx);

        const sink_node = ctx.nodes.get(sink);
        const edge_result = try ctx.addEdge(
            SourceKey{
                .node = self.node,
                .data = .{ .exec = output },
            },
            SinkKey{
                .node = sink,
                .data = switch (sink_node.data) {
                    .exec => .{ .exec = .{
                        .role = .stdin,
                    } },
                    .file => .{ .file = .{
                        .mode = .append,
                    } },
                },
            },
        );
        errdefer edge_result.deinit(ctx);
    }

    pub fn pipeFile(self: *const ExecBuilder, output: Pl.Edge.SourceData.Execution.Output, sink: FileIdx, config: PipeFileConfig) PipeError!void {
        const ctx = self.ctx;

        const dep = try ctx.dependOn(sink.idx, self.node, .started, .implicit);
        errdefer dep.deinit(ctx);

        const edge_result = try ctx.addEdge(
            SourceKey{
                .node = self.node,
                .data = .{ .exec = output },
            },
            SinkKey{
                .node = sink.idx,
                .data = .{ .file = .{
                    .mode = config.mode,
                    .path = config.path,
                } },
            },
        );
        errdefer edge_result.deinit(ctx);
    }

    pub const PipeFileConfig = struct {
        mode: Pl.Edge.TargetData.File.WriteMode = .append,
        path: ?[]const u8 = null,
    };
};

pub const FileIdx = struct {
    idx: NodeIdx,

    pub inline fn dependOn(self: FileIdx, other: *const ExecBuilder, wait_mode: Pl.Dependency.WaitMode) DependOnError!void {
        return other.ctx.dependOn(self.idx, other, wait_mode, .explicit);
    }

    pub fn pipeExec(self: FileIdx, sink: *const ExecBuilder, config: PipeFileConfig) ExecBuilder.PipeError!void {
        const ctx = sink.ctx;

        const dep = try ctx.dependOn(
            sink.node,
            self.idx,
            .started,
            .implicit,
        );
        errdefer dep.deinit(ctx);

        const edge_result = try ctx.addEdge(
            SourceKey{
                .node = self.idx,
                .data = .{ .file = .{
                    .path = config.path,
                } },
            },
            SinkKey{
                .node = sink.node,
                .data = .{ .exec = .{
                    .role = .stdin,
                } },
            },
        );
        errdefer edge_result.deinit(ctx);
    }

    pub const PipeFileConfig = struct {
        path: ?[]const u8 = null,
    };
};

const Node = struct {
    data: Data,

    sources: std.ArrayList(EdgeIdx) = .empty,
    sinks: std.ArrayList(EdgeIdx) = .empty,

    dep_on: StableList(DepIdx, u8) = .empty,
    dep_of: StableList(DepIdx, u8) = .empty,

    pub fn deinit(self: *Node, gpa: Allocator) void {
        self.data.deinit(gpa);

        self.sources.deinit(gpa);
        self.sinks.deinit(gpa);

        self.dep_on.deinit(gpa);
        self.dep_of.deinit(gpa);
    }

    const Data = union(enum) {
        exec: Execution,
        file: File,

        pub fn deinit(self: *Data, gpa: Allocator) void {
            switch (self.*) {
                .exec => self.exec.deinit(gpa),
                .file => self.file.deinit(gpa),
            }
        }

        const Execution = struct {
            args: std.ArrayList(Pl.Node.Data.Execution.ArgSlot) = .empty,
            env: std.process.Environ.Map,

            pub fn deinit(self: *Execution, gpa: Allocator) void {
                for (self.args.items) |*arg| {
                    arg.deinit(gpa);
                }
                self.args.deinit(gpa);

                self.env.deinit();
            }
        };

        const File = struct {
            path: []const u8,

            pub fn deinit(self: *File, gpa: Allocator) void {
                gpa.free(self.path);
            }
        };
    };
};

pub const Source = struct {
    node: NodeIdx,

    data: Pl.Source.Data,
    sinks_count: usize = 0,

    pub fn deinit(self: *Source, gpa: Allocator) void {
        self.data.deinit(gpa);
    }
};

pub const SourceKey = struct {
    node: NodeIdx,

    data: Pl.Source.Data,
};

// @Performance
pub const SourceHashContext = struct {
    pub fn hash(ctx: SourceHashContext, key: SourceKey) u64 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
        return hasher.final();
    }

    pub fn eql(ctx: SourceHashContext, a: SourceKey, b: SourceKey) bool {
        _ = ctx;
        return std.meta.eql(a, b);
    }
};

pub const Sink = struct {
    node: NodeIdx,

    data: Pl.Sink.Data,

    pub fn deinit(self: *Sink, gpa: Allocator) void {
        self.data.deinit(gpa);
    }
};

pub const SinkKey = struct {
    node: NodeIdx,

    data: Pl.Sink.Data,
};

// @Performance
pub const SinkHashContext = struct {
    pub fn hash(ctx: SinkHashContext, key: SinkKey) u64 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
        return hasher.final();
    }

    pub fn eql(ctx: SinkHashContext, a: SinkKey, b: SinkKey) bool {
        _ = ctx;
        return std.meta.eql(a, b);
    }
};

pub const Edge = struct {
    source: SourceIdx,
    sink: SinkIdx,
};

const Dependency = struct {
    node: NodeIdx,
    target: NodeIdx,

    wait_mode: Pl.Dependency.WaitMode,
    kind: Pl.Dependency.Kind,
};

const DependencyResult = struct {
    idx: DepIdx,
    node_idx: NodeDepIdx,
    target_idx: NodeDepIdx,

    previous_wait_mode: ?Pl.Dependency.WaitMode,
    previous_kind: ?Pl.Dependency.Kind,

    pub fn gotAdded(self: DependencyResult) bool {
        return self.previous_wait_mode == null and
            self.previous_kind == null;
    }

    pub fn deinit(self: DependencyResult, ctx: *Ctx) void {
        const dep = ctx.dependencies.get(self.idx);

        if (self.gotAdded()) {
            _ = ctx.dependencies.remove(self.idx);
            ctx.nodes.get(dep.node).dep_on.remove(self.node_idx);
            ctx.nodes.get(dep.target).dep_of.remove(self.target_idx);
        } else {
            dep.wait_mode = self.previous_wait_mode.?;
            dep.kind = self.previous_kind.?;
        }
    }
};

test "cricle dependency" {
    var ctx: Ctx = undefined;
    try Ctx.init(&ctx, testing.allocator, &Zlush.Config{
        .load_profile = false,
        .allow_creating_missing_directories_for_file_creation = false,
    });
    defer ctx.deinit();

    const a = try ctx.exec(&.{"echo"}, null);

    const b = try ctx.exec(&.{"cat"}, null);
    try a.pipe(b.node, .stdout);

    try testing.expectError(DependOnError.CircleDependency, a.dependOn(b.node, .finished));
}
