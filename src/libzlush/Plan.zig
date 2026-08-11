const std = @import("std");

const IndexT = @import("index.zig").IndexT;

pub const NodeIdx = IndexT(Node, u16);
pub const EdgeIdx = IndexT(Edge, u16);

const Plan = @This();

nodes: []Node,
edges: []Edge,

pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
    for (self.nodes) |*node| {
        node.deinit(allocator);
    }
    allocator.free(self.nodes);

    for (self.edges) |*edge| {
        edge.deinit(allocator);
    }
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
                captured: EdgeIdx,
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

pub const Edge = struct {
    source: NodeIdx,
    target: NodeIdx,
    source_data: SourceData,
    target_data: TargetData,

    pub fn deinit(self: *Edge, allocator: std.mem.Allocator) void {
        self.source_data.deinit(allocator);
        self.target_data.deinit(allocator);
    }

    pub const SourceData = union(enum) {
        exec: Execution,
        file: File,

        pub fn deinit(self: *SourceData, allocator: std.mem.Allocator) void {
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
            output: Output,

            pub const Output = struct {
                stdout: bool,
                stderr: bool,
            };
        };

        pub const File = struct {
            path: ?[]const u8 = null,
        };
    };

    pub const TargetData = union(enum) {
        exec: Execution,
        file: File,

        pub fn deinit(self: *TargetData, allocator: std.mem.Allocator) void {
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

pub const Dependency = struct {
    idx: NodeIdx,
    kind: Kind,

    pub const Kind = enum {
        implicit,
        explicit,
    };
};
