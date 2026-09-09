const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const CircBuffer = @import("common/CircBuffer.zig").CircBuffer;
const Indexes = @import("common/index.zig");
const MultiReaderCircBuffer = @import("common/MultiReaderCircBuffer.zig").MultiReaderCircBuffer;
const SparseSet = @import("common/SparseSet.zig").SparseSet;
const Pl = @import("Plan.zig");
const PlB = @import("builder/PlanBuilder.zig");
const NodeIdx = Pl.NodeIdx;
const SourceIdx = Pl.SourceIdx;
const SinkIdx = Pl.SinkIdx;
const PipeIdx = Pl.EdgeIdx;

const NodeSet = SparseSet(Node, Pl.NodeIdx.UnderlyingT, .@"64");
const SourceSet = SparseSet(Source, Pl.SourceIdx.UnderlyingT, .@"64");
const SinkSet = SparseSet(Sink, Pl.SinkIdx.UnderlyingT, .@"64");
const PipeSet = SparseSet(Pipe, Pl.EdgeIdx.UnderlyingT, .@"64");

const Engine = @This();

gpa: std.mem.Allocator,
plan: *const Pl,

nodes: NodeSet,
remaining_nodes: Pl.NodeIdx.UnderlyingT,

sources: SourceSet,
sinks: SinkSet,

pipes: PipeSet,

pub fn init(self: *Engine, gpa: std.mem.Allocator, plan: *const Pl) Allocator.Error!void {
    self.gpa = gpa;
    self.plan = plan;

    try NodeSet.initCapacity(&self.nodes, gpa, self.plan.nodes.len);
    errdefer {
        for (self.nodes.items()) |*node| {
            node.deinit(self.gpa);
        }
        self.nodes.deinit(self.gpa);
    }
    self.remaining_nodes = @intCast(self.plan.nodes.len);

    self.sources = .empty;
    self.sinks = .empty;
    self.pipes = .empty;

    for (self.plan.nodes, 0..) |*node, i| {
        const idx = NodeIdx.from(@intCast(i));

        try self.nodes.set(self.gpa, idx.value(), Node{
            .idx = idx,

            .instance = undefined,
            .interface = &node.interface,

            .dep_counter = @intCast(node.dep_on.len),
            .status = .waiting,
        });
    }
}

pub fn deinit(self: *Engine) void {
    for (self.nodes.items()) |*node| {
        node.deinit(self.gpa);
    }
    self.nodes.deinit(self.gpa);

    for (self.sources.items()) |*source| {
        source.deinit(self.gpa);
    }
    self.sources.deinit(self.gpa);

    for (self.sinks.items()) |*sink| {
        sink.deinit(self.gpa);
    }
    self.sinks.deinit(self.gpa);

    self.pipes.deinit(self.gpa);
}

/// returns `true` as long as there are active nodes
pub fn tick(self: *Engine) Allocator.Error!bool {
    for (self.nodes.items()) |*node| {
        try node.tick(self);
    }

    for (self.pipes.items()) |*pipe| {
        try pipe.tick(self);
    }

    return self.remaining_nodes != 0;
}

fn spawnNode(self: *Engine, node_idx: NodeIdx) Allocator.Error!void {
    const node = self.nodes.get(node_idx.value()).?;
    if (node.status != .waiting) {
        return;
    }

    const pl_node = self.plan.getNode(node_idx);
    for (pl_node.sources) |edge_idx| {
        const pl_edge = self.plan.getEdge(edge_idx);
        const source_idx = pl_edge.source;
        const sink_idx = pl_edge.sink;

        const source = try self.spawnSource(source_idx);
        _ = try self.spawnSink(sink_idx);

        const reader_idx = try source.buf.registerReader(self.gpa);
        errdefer source.buf.unregisterReader(reader_idx);
        try self.pipes.set(self.gpa, edge_idx.value(), Pipe{
            .edge = edge_idx,

            .source = source_idx,
            .sink = sink_idx,

            .reader_idx = reader_idx,
            .incomplete_write = null,
        });
    }

    node.instance = try node.interface.spawn(self.gpa);

    node.status = .started;
    self.notifyDependencies(node_idx, .started);
}

fn spawnSource(self: *Engine, idx: Pl.SourceIdx) Allocator.Error!*Source {
    if (self.sources.get(idx.value())) |source| {
        return source;
    }

    const pl_source = self.plan.getSource(idx);

    const source = try self.sources.add(self.gpa, idx.value());
    errdefer self.sources.remove(idx.value());

    try Source.init(source, self.gpa, idx, pl_source.sinks_count, pl_source.buf_capacity, pl_source.buf_limit);
    errdefer source.deinit(self.gpa);

    return source;
}

fn spawnSink(self: *Engine, idx: Pl.SinkIdx) Allocator.Error!*Sink {
    if (self.sinks.get(idx.value())) |sink| {
        return sink;
    }

    const pl_sink = self.plan.getSink(idx);

    const sink = try self.sinks.add(self.gpa, idx.value());
    errdefer self.sinks.remove(idx.value());

    try Sink.init(sink, self.gpa, idx, pl_sink.buf_capacity, pl_sink.buf_limit);
    errdefer sink.deinit(self.gpa);

    return sink;
}

fn notifyDependencies(self: *Engine, node_idx: NodeIdx, wait_mode: Pl.Dependency.WaitMode) void {
    const pl_node = self.plan.getNode(node_idx);

    for (pl_node.dep_of) |dep_idx| {
        const dep: *const Pl.Dependency = self.plan.getDependency(dep_idx);
        if (dep.wait_mode != wait_mode) {
            continue;
        }

        const dep_node = self.nodes.get(dep.node.value()).?;
        dep_node.dep_counter -= 1;
    }
}

pub const Node = struct {
    idx: NodeIdx,

    instance: *anyopaque,
    interface: *const Pl.Node.Interface,

    dep_counter: Pl.DepIdx.UnderlyingT,
    status: Status,

    pub const Status = union(enum) {
        waiting,
        started,
        finished,
        failed: Pl.Node.ExitCode,
    };

    pub fn deinit(self: *Node, gpa: Allocator) void {
        self.interface.cleanup(self.instance, gpa);
    }

    pub fn tick(self: *Node, engine: *Engine) Allocator.Error!void {
        switch (self.status) {
            .waiting => {
                if (self.dep_counter != 0) {
                    return;
                }

                try engine.spawnNode(self.idx);
            },
            .started => {
                switch (try self.interface.tick(self.instance, .fromEngine(engine))) {
                    .running => {},
                    .exit => |exit| {
                        engine.remaining_nodes -= 1;

                        switch (exit) {
                            .done => {
                                self.status = .finished;
                                engine.notifyDependencies(self.idx, .finished);
                            },
                            else => |code| {
                                self.status = .{ .failed = code };
                            },
                        }
                    },
                }
            },
            .finished => {
                // TODO: do something based on the type of Node
                // TODO: cleanup?
            },
            .failed => {
                // TODO: cleanup?
            },
        }
    }
};

pub const Source = struct {
    const Buffer = MultiReaderCircBuffer(u8);
    pub const ReaderIdx = Buffer.ReaderIdx;

    idx: SourceIdx,

    buf: Buffer,

    pub fn init(self: *Source, gpa: Allocator, idx: SourceIdx, reader_capacity: u8, capacity: u31, limit: u31) Allocator.Error!void {
        self.idx = idx;

        try Buffer.initCapacity(&self.buf, gpa, capacity, limit, reader_capacity);
        errdefer self.buf.deinit(gpa);
    }

    pub fn deinit(self: *Source, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }
};

pub const Sink = struct {
    const SinkBuffer = CircBuffer(u8);

    idx: SinkIdx,

    buf: SinkBuffer,
    incomplete_write_pipe_idx: ?PipeIdx,

    pub fn init(self: *Sink, gpa: Allocator, idx: SinkIdx, capacity: u31, limit: u31) Allocator.Error!void {
        self.idx = idx;

        try SinkBuffer.initCapacity(&self.buf, gpa, capacity, limit);
        errdefer self.buf.deinit(gpa);
        self.incomplete_write_pipe_idx = null;
    }

    pub fn deinit(self: *Sink, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }
};

pub const Pipe = struct {
    edge: Pl.EdgeIdx,

    source: SourceIdx,
    sink: SinkIdx,

    reader_idx: Source.ReaderIdx,
    incomplete_write: ?u32,

    pub fn tick(self: *Pipe, engine: *Engine) Allocator.Error!void {
        const ctx: *Context = .fromEngine(engine);
        const gpa = ctx.getGPA();

        const source = ctx.getSource(self.source);
        const sink = ctx.getSink(self.sink);

        if (sink.incomplete_write_pipe_idx) |idx| {
            if (self.edge != idx) {
                return;
            }
        }

        const to_read = self.incomplete_write orelse sink.buf.availableSpace();
        const data = source.buf.peek(self.reader_idx, to_read);

        // TODO: add write function to Sink which writes directly, if possible
        const written = sink.buf.write(gpa, data);
        source.buf.toss(self.reader_idx, written);

        if (data.len > written) {
            self.incomplete_write = @intCast(data.len - written);

            comptime std.debug.assert(Pl.EdgeIdx == PipeIdx);
            sink.incomplete_write_pipe_idx = self.edge;
        } else if (self.incomplete_write != null) {
            self.incomplete_write = null;
            sink.incomplete_write_pipe_idx = null;
        }
    }
};

pub const Context = struct {
    fn fromEngine(engine: *Engine) *Context {
        return @ptrCast(@alignCast(engine));
    }

    pub fn getGPA(self: *Context) Allocator {
        const engine: *Engine = @ptrCast(@alignCast(self));

        return engine.gpa;
    }

    pub fn getNode(self: *Context, idx: NodeIdx) *Node {
        const engine: *Engine = @ptrCast(@alignCast(self));

        return engine.nodes.get(idx.value()).?;
    }

    pub fn getSource(self: *Context, idx: SourceIdx) *Source {
        const engine: *Engine = @ptrCast(@alignCast(self));

        return engine.sources.get(idx.value()).?;
    }

    pub fn getSink(self: *Context, idx: SinkIdx) *Sink {
        const engine: *Engine = @ptrCast(@alignCast(self));

        return engine.sinks.get(idx.value()).?;
    }
};

fn writeGarbage(ptr: *anyopaque) Pl.Node.Data.Custom.ExitCode {
    _ = ptr;
    return .running;
}

fn printInputFor(comptime n: usize) Pl.Node.Data.Custom.TickFn {
    return struct {
        pub fn func(ptr: *anyopaque) ?Pl.Node.Data.Custom.TickResult {
            const counter: *usize = @ptrCast(@alignCast(ptr));
            if (counter.* >= n) {
                return .done;
            }

            // TODO: read from sink and print to debug output

            return .done;
        }
    }.func;
}

test "simple" {
    // var counter: usize = 0;

    var builder: PlB = undefined;
    try PlB.init(&builder, testing.allocator, &.{
        .load_profile = false,
        .allow_creating_missing_directories_for_file_creation = false,
    });
    defer builder.deinit();

    const b = try builder.exec(&.{"cat"}, null);

    const a = try builder.exec(&.{"echo"}, null);
    try builder.pipe(try a.getStdOut(), try b.getStdIn());

    _ = try builder.dependOn(b.node, a.node, .finished);

    var plan = try builder.plan(testing.allocator);
    defer plan.deinit(testing.allocator);

    var engine: Engine = undefined;
    try Engine.init(&engine, testing.allocator, &plan);
    defer engine.deinit();

    while (try engine.tick()) {}
}
