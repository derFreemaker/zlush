const std = @import("std");

const IndexT = @import("index.zig").IndexT;

pub const NodeIdx = IndexT(Node, u16);

pub const SourceIdx = IndexT(Source, u16);
pub const SinkIdx = IndexT(Sink, u16);

pub const EdgeIdx = IndexT(Edge, u16);

// Plan
const Pl = @This();

nodes: []Node,

sources: []Source,
sinks: []Sink,

edges: []Edge,

pub fn deinit(self: *Pl, allocator: std.mem.Allocator) void {
    for (self.nodes) |*node| {
        node.deinit(allocator);
    }
    allocator.free(self.nodes);

    for (self.sources) |*source| {
        source.deinit(allocator);
    }
    allocator.free(self.sources);

    for (self.sinks) |*sink| {
        sink.deinit(allocator);
    }
    allocator.free(self.sinks);

    allocator.free(self.edges);
}

pub const Node = struct {
    data: Data,

    sources: []EdgeIdx,
    sinks: []EdgeIdx,

    depends_on: []Dependency,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);

        allocator.free(self.sources);
        allocator.free(self.sinks);

        allocator.free(self.depends_on);
    }

    pub const Data = union(enum) {
        exec: Execution,
        file: File,

        pub fn deinit(self: *Data, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .exec => self.exec.deinit(allocator),
                .file => self.file.deinit(allocator),
            }
        }

        pub const Execution = struct {
            args: []ArgSlot,
            env: std.process.Environ.Map,

            collect_stdout: bool,
            collect_stderr: bool,

            pub fn deinit(self: *Execution, allocator: std.mem.Allocator) void {
                for (self.args) |*arg| {
                    arg.deinit(allocator);
                }
                allocator.free(self.args);

                self.env.deinit();
            }

            pub const ArgSlot = union(enum) {
                literal: []const u8,
                captured: SinkIdx,
                start_concat,
                end_concat,

                pub fn deinit(self: *ArgSlot, allocator: std.mem.Allocator) void {
                    switch (self.*) {
                        .literal => |literal| allocator.free(literal),
                        else => {},
                    }
                }
            };
        };

        pub const File = struct {
            path: []const u8,

            pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
                allocator.free(self.path);
            }
        };
    };
};

pub const Source = struct {
    node: NodeIdx,
    data: Data,
    sinks_count: usize,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    pub const Data = union(enum) {
        exec: ExecutionOutput,
        file: File,

        pub fn deinit(self: *Data, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .file => |file| {
                    if (file.path) |path| {
                        allocator.free(path);
                    }
                },
                else => {},
            }
        }

        pub const ExecutionOutput = enum {
            stderr,
            stdout,
        };

        pub const File = struct {
            path: ?[]const u8 = null,
        };
    };
};

pub const Sink = struct {
    node: NodeIdx,
    data: Data,

    pub fn deinit(self: *Sink, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    pub const Data = union(enum) {
        exec: Execution,
        file: File,

        pub fn deinit(self: *Data, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .file => |file| {
                    if (file.path) |path| {
                        allocator.free(path);
                    }
                },
                else => {},
            }
        }

        pub const Execution = struct {
            role: Role,

            pub const Role = union(enum) {
                stdin,
                arg: Arg,

                pub const Arg = struct {
                    idx: usize,
                    trim: Trim = .trim_newlines,

                    pub const Trim = enum {
                        no_trim,
                        trim_newlines,
                    };
                };
            };
        };

        pub const File = struct {
            path: ?[]const u8 = null,
            mode: WriteMode = .append,

            pub const WriteMode = enum {
                append,
                write_trunc,
            };
        };
    };
};

pub const Edge = struct {
    source: SourceIdx,
    sink: SinkIdx,
};

pub const Dependency = struct {
    idx: NodeIdx,
    kind: Kind,

    pub const Kind = enum {
        implicit,
        explicit,
    };
};
