const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const CircBuffer = @import("common/CircBuffer.zig").CircBuffer;
const Indexes = @import("common/index.zig");
const MultiReaderCircBuffer = @import("common/MultiReaderCircBuffer.zig").MultiReaderCircBuffer;
const SparseSet = @import("common/SparseSet.zig").SparseSet;
const Plan = @import("Plan.zig");
const NodeIdx = Plan.NodeIdx;
const SourceIdx = Plan.SourceIdx;
const SinkIdx = Plan.SinkIdx;
const PipeIdx = Plan.EdgeIdx;

const NodeSet = SparseSet(Node, Plan.NodeIdx.UnderlyingT, .@"64");
const SourceSet = SparseSet(Source, Plan.SourceIdx.UnderlyingT, .@"64");
const SinkSet = SparseSet(Sink, Plan.SinkIdx.UnderlyingT, .@"64");
const PipeSet = SparseSet(Pipe, Plan.EdgeIdx.UnderlyingT, .@"64");

const Engine = @This();

gpa: std.mem.Allocator,
plan: *const Plan,

nodes: NodeSet,
sources: SourceSet,
sinks: SinkSet,
pipes: PipeSet,

pub fn init(self: *Engine, gpa: std.mem.Allocator, plan: *const Plan) Allocator.Error!void {
    self.gpa = gpa;
    self.plan = plan;

    try NodeSet.initCapacity(&self.nodes, gpa, self.plan.nodes.len);
    errdefer self.nodes.deinit(self.gpa);

    self.sources = .empty;
    self.sinks = .empty;
    self.pipes = .empty;

    for (self.plan.nodes, 0..) |node, i| {
        const idx = NodeIdx.from(@intCast(i));
        try self.nodes.set(idx, Node{
            .idx = idx,

            .userdata = undefined,
            .vtable = node.vtable,

            .dep_counter = @intCast(node.dep_on.len),
            .status = .waiting,
        });
    }
}

pub fn deinit(self: *Engine) void {
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

pub fn tick(self: *Engine) Allocator.Error!void {
    for (self.nodes.items()) |*node| {
        try node.tick(self);
    }

    for (self.sources.items()) |*source| {
        try source.tick(self);
    }

    for (self.pipes.items()) |*pipe| {
        try pipe.tick(self);
    }
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

        const pl_source = self.plan.getSource(source_idx);

        var source: Source = undefined;
        try Source.init(&source, self.gpa, source_idx, pl_source.sinks_count, pl_source.buf_capacity, pl_source.buf_limit);
        errdefer source.deinit(self.gpa);
        try self.sources.set(self.gpa, source_idx.value(), source);

        const reader_idx = try source.buf.registerReader(self.gpa);
        errdefer source.buf.unregisterReader(reader_idx);
        try self.pipes.set(self.gpa, edge_idx.value(), Pipe{
            .edge = edge_idx,

            .source = source_idx,
            .sink = sink_idx,

            .reader_idx = reader_idx,
            .incomplete_write = null,
        });

        const pl_sink = self.plan.getSink(sink_idx);

        var sink: Sink = undefined;
        try Sink.init(&sink, self.gpa, sink_idx, pl_sink.buf_capacity, pl_sink.buf_limit);
        errdefer sink.deinit(self.gpa);
        try self.sinks.set(self.gpa, sink_idx.value(), sink);
    }

    node.instance = try node.interface.spawn(self.gpa);

    node.status = .started;
    self.notifyDependencies(node_idx, .started);
}

fn notifyDependencies(self: *Engine, node_idx: NodeIdx, wait_mode: Plan.Dependency.WaitMode) void {
    const pl_node = self.plan.getNode(node_idx);

    for (pl_node.dep_of) |dep_idx| {
        const dep: *const Plan.Dependency = self.plan.getDependency(dep_idx);
        if (dep.wait_mode != wait_mode) {
            continue;
        }

        const dep_node = self.nodes.get(dep.target.value()).?;
        dep_node.dep_counter -= 1;
    }
}

pub const Node = struct {
    idx: NodeIdx,

    instance: *anyopaque,
    interface: *const Plan.Node.Interface,

    dep_counter: Plan.DepIdx.UnderlyingT,
    status: Status,

    pub const Status = union(enum) {
        waiting,
        started,
        finished,
        failed: Plan.Node.ExitCode,
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
                switch (try self.interface.tick(self.instance)) {
                    .running => {},
                    .exit => |exit| {
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
    edge: Plan.EdgeIdx,

    source: SourceIdx,
    sink: SinkIdx,

    reader_idx: Source.ReaderIdx,
    incomplete_write: ?u32,

    pub fn tick(self: *Pipe, engine: *Engine) Allocator.Error!void {
        const source = engine.sources.get(self.source).?;
        const sink = engine.sinks.get(self.sink).?;

        if (sink.incomplete_write_pipe_idx) |idx| {
            if (self.edge != idx) {
                return;
            }
        }

        const to_read = self.incomplete_write orelse sink.buf.availableSpace();
        const data = source.buf.peek(self.reader_idx, to_read);

        // TODO: add write function to Sink which writes directly, if possible
        const written = sink.buf.write(engine.gpa, data);
        source.buf.toss(self.reader_idx, written);

        if (data.len > written) {
            self.incomplete_write = data.len - written;

            comptime std.debug.assert(Plan.EdgeIdx == PipeIdx);
            sink.incomplete_write_pipe_idx = self.edge;
        } else if (self.incomplete_write != null) {
            self.incomplete_write = null;
            sink.incomplete_write_pipe_idx = null;
        }
    }
};

fn writeGarbage(ptr: *anyopaque) Plan.Node.Data.Custom.ExitCode {
    _ = ptr;
    return .running;
}

fn printInputFor(comptime n: usize) Plan.Node.Data.Custom.TickFn {
    return struct {
        pub fn func(ptr: *anyopaque) ?Plan.Node.Data.Custom.TickResult {
            const counter: *usize = @ptrCast(@alignCast(ptr));
            if (counter.* >= n) {
                return .done;
            }

            // TODO: read from sink and print to debug output

            return .done;
        }
    }.func;
}

// test "simple" {
//     var counter: usize = 0;

//     var engine: Engine = undefined;
//     try Engine.init(&engine, testing.allocator, &Plan{
//         .nodes = &[_]Plan.Node{
//             Plan.Node{
//                 .sinks = &.{},
//                 .sources = &.{},

//                 .dep_on = &.{},
//                 .dep_of = &.{},

//                 .data = .{
//                     .custom = .{
//                         .userdata = undefined,
//                         .tick = writeGarbage,
//                     },
//                 },
//             },
//             Plan.Node{
//                 .sinks = &.{},
//                 .sources = &.{},

//                 .dep_on = &.{},
//                 .dep_of = &.{},

//                 .data = .{
//                     .custom = .{
//                         .userdata = &counter,
//                         .tick = printInputFor(32),
//                     },
//                 },
//             },
//         },

//         .sources = &[_]Plan.Source{},
//         .sinks = &[_]Plan.Sink{},

//         .edges = &[_]Plan.Edge{},
//         .dependencies = &[_]Plan.Dependency{},
//     });
// }
