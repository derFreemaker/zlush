const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const StableList = @import("../common/StableList.zig").StableList;
const ExecNode = @import("../nodes/ExecNode.zig");
const Pl = @import("../Plan.zig");
const Zlush = @import("../Zlush.zig");
const ExecBuilder = @import("ExecBuilder.zig");

const NodeList = StableList(Node, Pl.NodeIdx.UnderlyingT);
pub const NodeIdx = NodeList.Index;
const SourceList = StableList(Source, Pl.SourceIdx.UnderlyingT);
pub const SourceIdx = SourceList.Index;
const SinkList = StableList(Sink, Pl.SinkIdx.UnderlyingT);
pub const SinkIdx = SinkList.Index;
const EdgeList = StableList(Edge, Pl.EdgeIdx.UnderlyingT);
pub const EdgeIdx = EdgeList.Index;
const DepList = StableList(Dependency, Pl.DepIdx.UnderlyingT);
const DepIdx = DepList.Index;
const NodeDepList = StableList(DepIdx, Pl.DepIdx.UnderlyingT);
const NodeDepIdx = NodeDepList.Index;
const NodeSourceList = StableList(EdgeIdx, Pl.EdgeIdx.UnderlyingT);
const NodeSourceIdx = NodeSourceList.Index;
const NodeSinkList = StableList(EdgeIdx, Pl.EdgeIdx.UnderlyingT);
const NodeSinkIdx = NodeSinkList.Index;

const PlanBuilder = @This();

gpa: Allocator,

// CLEANUP: make own config section for execution
config: *const Zlush.Config,

nodes: NodeList,

sources: SourceList,
sinks: SinkList,

edges: EdgeList,
dependencies: DepList,

pub fn init(self: *PlanBuilder, gpa: Allocator, config: *const Zlush.Config) Allocator.Error!void {
    self.gpa = gpa;
    self.config = config;

    try NodeList.initCapacity(&self.nodes, gpa, 32);
    errdefer self.nodes.deinit(gpa);

    try SourceList.initCapacity(&self.sources, gpa, 32);
    errdefer self.sources.deinit(gpa);

    try SinkList.initCapacity(&self.sinks, gpa, 32);
    errdefer self.sinks.deinit(gpa);

    try EdgeList.initCapacity(&self.edges, gpa, 32);
    errdefer self.edges.deinit(gpa);

    try DepList.initCapacity(&self.dependencies, gpa, 32);
    errdefer self.dependencies.deinit(gpa);
}

pub fn deinit(self: *PlanBuilder) void {
    for (self.nodes.sparse.items()) |*node| {
        node.deinit(self.gpa);
    }
    self.nodes.deinit(self.gpa);

    self.sources.deinit(self.gpa);
    self.sinks.deinit(self.gpa);

    self.edges.deinit(self.gpa);
    self.dependencies.deinit(self.gpa);
}

pub fn dependsOn(self: *const PlanBuilder, a: NodeIdx, b: NodeIdx) bool {
    if (a == b) {
        return false;
    }

    const node = self.nodes.get(a);
    for (node.dep_on.items()) |dep_idx| {
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

/// returns a struct with the nessecarry information to undo the dependency
pub fn dependOn(self: *PlanBuilder, node_idx: NodeIdx, target_idx: NodeIdx, wait_mode: Pl.Dependency.WaitMode) DependOnError!DependencyResult {
    return self.dependOnImpl(node_idx, target_idx, wait_mode, .explicit);
}

/// returns a struct with the nessecarry information to undo the dependency
fn dependOnImpl(self: *PlanBuilder, node_idx: NodeIdx, target_idx: NodeIdx, wait_mode: Pl.Dependency.WaitMode, kind: Pl.Dependency.Kind) DependOnError!DependencyResult {
    if (self.dependsOn(target_idx, node_idx)) {
        return DependOnError.CircleDependency;
    }

    const node = self.nodes.get(node_idx);
    for (node.dep_on.items()) |dep_idx| {
        const dep = self.dependencies.get(dep_idx);
        if (dep.target == target_idx) {
            const result = DependencyResult{
                .idx = dep_idx,
                .node_idx = dep.node,
                .target_idx = dep.target,

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
        .node = node_idx,
        .target = target_idx,

        .wait_mode = wait_mode,
        .kind = kind,
    });
    errdefer self.dependencies.remove(dep_idx);

    const node_dep_idx = try node.dep_on.append(self.gpa, dep_idx);
    errdefer _ = node.dep_on.remove(node_dep_idx);

    const target_node = self.nodes.get(target_idx);
    const target_dep_idx = try target_node.dep_of.append(self.gpa, dep_idx);
    errdefer _ = target_node.dep_of.remove(target_dep_idx);

    return DependencyResult{
        .idx = dep_idx,
        .node_idx = node_dep_idx,
        .target_idx = target_dep_idx,

        .previous_wait_mode = null,
        .previous_kind = null,
    };
}

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

    pub fn undo(self: DependencyResult, builder: *PlanBuilder) void {
        const dep = builder.dependencies.get(self.idx);

        if (self.gotAdded()) {
            _ = builder.dependencies.remove(self.idx);
            builder.nodes.get(dep.node).dep_on.remove(self.node_idx);
            builder.nodes.get(dep.target).dep_of.remove(self.target_idx);
        } else {
            dep.wait_mode = self.previous_wait_mode.?;
            dep.kind = self.previous_kind.?;
        }
    }
};

pub fn addSource(self: *PlanBuilder, node_idx: NodeIdx) Allocator.Error!SourceIdx {
    const idx = try self.sources.append(self.gpa, Source{
        .node = node_idx,
    });
    errdefer self.sources.remove(idx);

    return idx;
}

pub fn removeSource(self: *PlanBuilder, source_idx: SourceIdx) void {
    self.sources.remove(source_idx);
}

pub fn addSink(self: *PlanBuilder, node_idx: NodeIdx) Allocator.Error!SinkIdx {
    const idx = try self.sinks.append(self.gpa, Sink{
        .node = node_idx,
    });
    errdefer self.sinks.remove(idx);

    return idx;
}

pub fn removeSink(self: *PlanBuilder, sink_idx: SinkIdx) void {
    self.sinks.remove(sink_idx);
}

/// returns a struct with the nessecarry information to undo the edge
fn addEdge(self: *PlanBuilder, source_idx: SourceIdx, sink_idx: SinkIdx) Allocator.Error!EdgeResult {
    const idx = try self.edges.append(self.gpa, Edge{
        .source = source_idx,
        .sink = sink_idx,
    });
    errdefer self.edges.remove(idx);

    const source = self.sources.get(source_idx);
    source.sinks_count += 1;
    errdefer source.sinks_count -= 1;

    const sink = self.sinks.get(sink_idx);
    sink.sources_count += 1;
    errdefer sink.sources_count -= 1;

    const source_node = self.nodes.get(source.node);
    const node_source_idx = try source_node.sources.append(self.gpa, idx);
    errdefer source_node.sources.remove(node_source_idx);

    const sink_node = self.nodes.get(sink.node);
    const node_sink_idx = try sink_node.sinks.append(self.gpa, idx);
    errdefer sink_node.sinks.remove(node_sink_idx);

    return EdgeResult{
        .idx = idx,

        .source_idx = source_idx,
        .sink_idx = sink_idx,

        .node_source_idx = node_source_idx,
        .node_sink_idx = node_sink_idx,
    };
}

pub const EdgeResult = struct {
    idx: EdgeIdx,

    source_idx: SourceIdx,
    sink_idx: SinkIdx,

    node_source_idx: NodeSourceIdx,
    node_sink_idx: NodeSinkIdx,

    pub fn undo(self: *const EdgeResult, builder: *PlanBuilder) void {
        builder.edges.remove(self.idx);

        const source = builder.sources.get(self.source_idx);
        source.sinks_count -= 1;
        const source_node = builder.nodes.get(source.node);
        source_node.sources.remove(self.node_source_idx);

        const sink = builder.sinks.get(self.sink_idx);
        sink.sources_count -= 1;
        const sink_node = builder.nodes.get(sink.node);
        sink_node.sources.remove(self.node_sink_idx);
    }
};

pub const PipeError = Allocator.Error || PlanBuilder.DependOnError;

pub fn pipe(self: *PlanBuilder, source_idx: SourceIdx, sink_idx: SinkIdx) PipeError!void {
    const source = self.sources.get(source_idx);
    const sink = self.sinks.get(sink_idx);

    const dep = try self.dependOnImpl(sink.node, source.node, .started, .implicit);
    errdefer dep.undo(self);

    const edge_result = try self.addEdge(source_idx, sink_idx);
    errdefer edge_result.undo(self);
}

pub const ExecCreationError = Allocator.Error || error{
    NoArgProvided,
};

pub fn exec(self: *PlanBuilder, args: []const []const u8, env_map: ?*const std.process.Environ.Map) ExecCreationError!ExecBuilder {
    if (args.len == 0) {
        return ExecCreationError.NoArgProvided;
    }

    return try ExecBuilder.init(self, args, env_map);
}

// pub fn registerFile(self: *PlanBuilder, path: []const u8) Allocator.Error!FileIdx {
//     const copy = try self.gpa.dupe(u8, path);
//     errdefer self.gpa.free(copy);

//     const node_idx = try self.nodes.append(self.gpa, Node{
//         .data = .{ .file = .{
//             .path = copy,
//         } },
//     });
//     errdefer _ = self.nodes.pop();

//     return FileIdx{
//         .idx = node_idx,
//     };
// }

// pub fn pipeFile(self: *const ExecBuilder, output: Plan.Edge.SourceData.Execution.Output, sink: FileIdx, config: PipeFileConfig) PipeError!void {
//     const ctx = self.ctx;

//     const dep = try ctx.dependOn(sink.idx, self.node, .started, .implicit);
//     errdefer dep.deinit(ctx);

//     const edge_result = try ctx.addEdge(
//         SourceKey{
//             .node = self.node,
//             .data = .{ .exec = output },
//         },
//         SinkKey{
//             .node = sink.idx,
//             .data = .{ .file = .{
//                 .mode = config.mode,
//                 .path = config.path,
//             } },
//         },
//     );
//     errdefer edge_result.deinit(ctx);
// }

// pub const PipeFileConfig = struct {
//     mode: Plan.Edge.TargetData.File.WriteMode = .append,
//     path: ?[]const u8 = null,
// };

pub fn plan(self: *const PlanBuilder, gpa: Allocator) Allocator.Error!Pl {
    var node_i: usize = 0;
    const nodes = try gpa.alloc(Pl.Node, self.nodes.len());
    errdefer {
        for (nodes[0..node_i]) |*node| {
            node.deinit(gpa);
        }
        gpa.free(nodes);
    }
    for (self.nodes.items()) |node| {
        const copy = &nodes[node_i];

        copy.interface = try node.interface.clone(gpa);
        errdefer copy.interface.deinit(gpa);

        copy.sources = try gpa.alloc(Pl.EdgeIdx, node.sources.len());
        errdefer gpa.free(copy.sources);
        for (node.sources.items(), 0..) |source_idx, i| {
            copy.sources[i] = Pl.EdgeIdx.from(source_idx.value());
        }

        copy.sinks = try gpa.alloc(Pl.EdgeIdx, node.sinks.len());
        errdefer gpa.free(copy.sinks);
        for (node.sinks.items(), 0..) |sink_idx, i| {
            copy.sinks[i] = Pl.EdgeIdx.from(sink_idx.value());
        }

        copy.dep_on = try gpa.alloc(Pl.DepIdx, node.dep_on.len());
        errdefer gpa.free(copy.dep_on);
        for (node.dep_on.items(), 0..) |dep_idx, i| {
            copy.dep_on[i] = Pl.DepIdx.from(dep_idx.value());
        }

        copy.dep_of = try gpa.alloc(Pl.DepIdx, node.dep_of.len());
        errdefer gpa.free(copy.dep_of);
        for (node.dep_of.items(), 0..) |dep_idx, i| {
            copy.dep_of[i] = Pl.DepIdx.from(dep_idx.value());
        }

        node_i += 1;
    }

    const sources = try gpa.alloc(Pl.Source, self.sources.len());
    errdefer gpa.free(sources);
    for (self.sources.items(), 0..) |source, i| {
        const copy = &sources[i];

        copy.node = Pl.NodeIdx.from(source.node.value());

        copy.buf_capacity = source.buf_capacity;
        copy.buf_limit = source.buf_limit;
        copy.sinks_count = source.sinks_count;
    }

    const sinks = try gpa.alloc(Pl.Sink, self.sinks.len());
    errdefer gpa.free(sinks);
    for (self.sinks.items(), 0..) |sink, i| {
        const copy = &sinks[i];

        copy.node = Pl.NodeIdx.from(sink.node.value());

        copy.buf_capacity = sink.buf_capacity;
        copy.buf_limit = sink.buf_limit;
        copy.sources_count = sink.sources_count;
    }

    const edges = try gpa.alloc(Pl.Edge, self.edges.len());
    errdefer gpa.free(edges);
    for (self.edges.items(), 0..) |edge, i| {
        const copy = &edges[i];

        copy.source = Pl.NodeIdx.from(edge.source.value());
        copy.sink = Pl.NodeIdx.from(edge.sink.value());
    }

    const dependencies = try gpa.alloc(Pl.Dependency, self.dependencies.len());
    errdefer gpa.free(dependencies);
    for (self.dependencies.items(), 0..) |dep, i| {
        const copy = &dependencies[i];

        copy.node = Pl.NodeIdx.from(dep.node.value());
        copy.target = Pl.NodeIdx.from(dep.target.value());

        copy.wait_mode = dep.wait_mode;
        copy.kind = dep.kind;
    }

    return Pl{
        .nodes = nodes,
        .sources = sources,
        .sinks = sinks,
        .edges = edges,
        .dependencies = dependencies,
    };
}

pub const FileIdx = struct {
    idx: NodeIdx,

    // pub inline fn dependOn(self: FileIdx, other: *const ExecBuilder, wait_mode: Plan.Dependency.WaitMode) DependOnError!void {
    //     return other.ctx.dependOn(self.idx, other, wait_mode, .explicit);
    // }

    // pub fn pipeExec(self: FileIdx, sink: *const ExecBuilder, config: PipeFileConfig) ExecBuilder.PipeError!void {
    //     const ctx = sink.ctx;

    //     const dep = try ctx.dependOn(
    //         sink.node,
    //         self.idx,
    //         .started,
    //         .implicit,
    //     );
    //     errdefer dep.deinit(ctx);

    //     const edge_result = try ctx.addEdge(
    //         SourceKey{
    //             .node = self.idx,
    //             .data = .{ .file = .{
    //                 .path = config.path,
    //             } },
    //         },
    //         SinkKey{
    //             .node = sink.node,
    //             .data = .{ .exec = .{
    //                 .role = .stdin,
    //             } },
    //         },
    //     );
    //     errdefer edge_result.deinit(ctx);
    // }

    // pub const PipeFileConfig = struct {
    //     path: ?[]const u8 = null,
    // };
};

pub const Node = struct {
    interface: Pl.Node.Interface,

    sources: StableList(EdgeIdx, Pl.EdgeIdx.UnderlyingT) = .empty,
    sinks: StableList(EdgeIdx, Pl.EdgeIdx.UnderlyingT) = .empty,

    dep_on: StableList(DepIdx, Pl.DepIdx.UnderlyingT) = .empty,
    dep_of: StableList(DepIdx, Pl.DepIdx.UnderlyingT) = .empty,

    pub fn deinit(self: *Node, gpa: Allocator) void {
        self.interface.deinit(gpa);

        self.sources.deinit(gpa);
        self.sinks.deinit(gpa);

        self.dep_on.deinit(gpa);
        self.dep_of.deinit(gpa);
    }
};

pub const Source = struct {
    node: NodeIdx,

    // TODO: set capacity equal to the per platform pipe limit by default (4K is the default for Linux)
    buf_capacity: u31 = 4 * 1024,
    buf_limit: u31 = 4 * 1024,
    sinks_count: u8 = 0,
};

pub const Sink = struct {
    node: NodeIdx,

    // TODO: set capacity equal to the per platform pipe limit by default (4K is the default for Linux)
    buf_capacity: u31 = 4 * 1024,
    buf_limit: u31 = 4 * 1024,
    sources_count: u8 = 0,
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

test "cricle dependency" {
    var builder: PlanBuilder = undefined;
    try PlanBuilder.init(&builder, testing.allocator, &Zlush.Config{
        .load_profile = false,
        .allow_creating_missing_directories_for_file_creation = false,
    });
    defer builder.deinit();

    const a = try builder.exec(&.{"echo"}, null);

    const b = try builder.exec(&.{"cat"}, null);
    try builder.pipe(try a.getStdOut(), try b.getStdIn());

    try testing.expectError(DependOnError.CircleDependency, builder.dependOn(a.node, b.node, .finished));

    var p = try builder.plan(testing.allocator);
    defer p.deinit(testing.allocator);
}
