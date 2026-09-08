const std = @import("std");
const Allocator = std.mem.Allocator;

const IndexT = @import("common/index.zig").IndexT;

pub const NodeIdx = IndexT(Node, u16);
pub const SourceIdx = IndexT(Source, u16);
pub const SinkIdx = IndexT(Sink, u16);
pub const EdgeIdx = IndexT(Edge, u16);
pub const DepIdx = IndexT(Dependency, u16);

const Plan = @This();

nodes: []Node,

sources: []Source,
sinks: []Sink,

edges: []Edge,
dependencies: []Dependency,

pub fn deinit(self: *Plan, gpa: Allocator) void {
    for (self.nodes) |*node| {
        node.deinit(gpa);
    }
    gpa.free(self.nodes);

    gpa.free(self.sources);
    gpa.free(self.sinks);

    gpa.free(self.edges);
    gpa.free(self.dependencies);
}

pub fn getNode(self: *const Plan, idx: NodeIdx) *const Node {
    return &self.nodes[idx.value()];
}

pub fn getSource(self: *const Plan, idx: SourceIdx) *const Source {
    return &self.sources[idx.value()];
}

pub fn getSink(self: *const Plan, idx: SinkIdx) *const Sink {
    return &self.sinks[idx.value()];
}

pub fn getEdge(self: *const Plan, idx: EdgeIdx) *const Edge {
    return &self.edges[idx.value()];
}

pub fn getDependency(self: *const Plan, idx: DepIdx) *const Dependency {
    return &self.dependencies[idx.value()];
}

pub const Node = struct {
    interface: Interface,

    sources: []EdgeIdx,
    sinks: []EdgeIdx,

    dep_on: []DepIdx,
    dep_of: []DepIdx,

    pub fn deinit(self: *Node, gpa: Allocator) void {
        self.interface.deinit(gpa);

        gpa.free(self.sources);
        gpa.free(self.sinks);

        gpa.free(self.dep_on);
        gpa.free(self.dep_of);
    }

    pub const Interface = struct {
        userdata: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            deinit: *const fn (userdata: *anyopaque, gpa: Allocator) void = noopDeinit,
            clone: *const fn (userdata: *anyopaque, gpa: Allocator) Allocator.Error!*anyopaque = noopClone,

            spawn: *const fn (userdata: *anyopaque, gpa: Allocator) Allocator.Error!*anyopaque = noopSpawn,
            cleanup: *const fn (userdata: *anyopaque, instance: *anyopaque, gpa: Allocator) void = noopCleanup,

            // TODO: pass sources and sinks
            tick: *const fn (userdata: *anyopaque, instance: *anyopaque) Allocator.Error!TickResult,
        };

        pub fn noopDeinit(userdata: *anyopaque, gpa: Allocator) void {
            _ = userdata;
            _ = gpa;
        }

        pub fn noopClone(userdata: *anyopaque, gpa: Allocator) Allocator.Error!*anyopaque {
            _ = userdata;
            _ = gpa;
            return undefined;
        }

        pub fn noopSpawn(userdata: *anyopaque, gpa: Allocator) Allocator.Error!*anyopaque {
            _ = userdata;
            _ = gpa;
            return undefined;
        }

        pub fn noopCleanup(userdata: *anyopaque, instance: *anyopaque, gpa: Allocator) void {
            _ = userdata;
            _ = instance;
            _ = gpa;
        }

        pub fn deinit(self: *const Interface, gpa: Allocator) void {
            self.vtable.deinit(self.userdata, gpa);
        }

        pub fn clone(self: *const Interface, gpa: Allocator) Allocator.Error!Interface {
            const copy = Interface{
                .userdata = try self.vtable.clone(self.userdata, gpa),
                .vtable = self.vtable,
            };
            return copy;
        }

        pub fn spawn(self: *const Interface, gpa: Allocator) Allocator.Error!*anyopaque {
            return self.vtable.spawn(self.userdata, gpa);
        }

        pub fn cleanup(self: *const Interface, instance: *anyopaque, gpa: Allocator) void {
            return self.vtable.cleanup(self.userdata, instance, gpa);
        }

        pub fn tick(self: *const Interface, instance: *anyopaque) Allocator.Error!TickResult {
            return self.vtable.tick(self.userdata, instance);
        }
    };

    pub const TickResult = union(enum) {
        running,
        exit: ExitCode,

        pub const done = TickResult{ .exit = .done };
        pub const failed = TickResult{ .exit = 1 };

        pub fn fromCode(code: u8) TickResult {
            return TickResult{ .exit = code };
        }
    };

    pub const ExitCode = enum(u8) {
        /// node successfully finished
        done = 0,
        /// node failed
        _,
    };
};

pub const Source = struct {
    node: NodeIdx,

    buf_capacity: u31,
    buf_limit: u31,
    sinks_count: usize,

    // TODO: provide option to write directly to a file / pipe
};

pub const Sink = struct {
    node: NodeIdx,

    buf_capacity: u31,
    buf_limit: u31,
    sources_count: usize,
};

pub const Edge = struct {
    source: SourceIdx,
    sink: SinkIdx,
};

pub const Dependency = struct {
    node: NodeIdx,
    target: NodeIdx,

    wait_mode: WaitMode,
    kind: Kind,

    pub const WaitMode = enum {
        started,
        finished,
    };

    pub const Kind = enum {
        implicit,
        explicit,
    };
};
