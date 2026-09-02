const std = @import("std");

const Indexes = @import("common/index.zig");
const MultiReaderCircBuffer = @import("common/MultiReaderCircBuffer.zig").MultiReaderCircBuffer;
const Pl = @import("Plan.zig");

const SourceIdx = Indexes.IndexT(Source, u16);
const SinkIdx = Indexes.IndexT(Sink, u16);

const Engine = @This();

gpa: std.mem.Allocator,
plan: *const Pl,

processes: std.ArrayList(Process),

sources: std.ArrayList(Source),
sinks: std.ArrayList(Sink),
pipes: std.ArrayList(Pipe),

pub fn init(self: *Engine, gpa: std.mem.Allocator, plan: *const Pl) void {
    self.gpa = gpa;
    self.plan = plan;

    self.processes = .empty;

    self.sources = .empty;
    self.sinks = .empty;
    self.pipes = .empty;
}

pub fn deinit(self: *Engine) void {
    self.processes.deinit(self.gpa);

    self.sources.deinit(self.gpa);
    self.sinks.deinit(self.gpa);
    self.pipes.deinit(self.gpa);
}

pub fn tick(self: *Engine) void {
    _ = self; // autofix
}

pub const Process = struct {
    node: Pl.NodeIdx,
};

pub const Source = struct {
    node: Pl.NodeIdx,

    // @TODO: actual source

    buf: MultiReaderCircBuffer(u8),

    pub fn init(self: *Source, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        _ = self; // autofix
        _ = gpa; // autofix
    }
};

pub const Sink = struct {
    node: Pl.NodeIdx,

    // @TODO: sink destination

    incomplete_edge_write: ?Pl.EdgeIdx,
};

pub const Pipe = struct {
    edge: Pl.EdgeIdx,

    reader_id: ?u32,
    source: SourceIdx,
    sink: SinkIdx,
};
