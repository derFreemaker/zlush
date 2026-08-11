const std = @import("std");

const IndexT = @import("index.zig").IndexT;

pub const NodeIdx = IndexT(Node, u16);
pub const EdgeIdx = IndexT(Edge, u16);

const Plan = @This();

allocator: std.mem.Allocator,

nodes: []Node,
edges: []Edge,

pub const Node = struct {
    data: Data,

    sources: []EdgeIdx,
    sinks: []EdgeIdx,

    depends_on: []Dependency,

    pub const Data = union(enum) {
        exec: Execution,
        file: File,

        pub const Execution = struct {
            args: []ArgSlot,
            env: std.process.Environ.Map,

            collect_stdout: bool,
            collect_stderr: bool,

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
        };
    };
};

pub const Edge = struct {
    source: NodeIdx,
    target: NodeIdx,
    source_data: SourceData,
    target_data: TargetData,

    pub const SourceData = union(enum) {
        exec: Execution,
        file: File,

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
