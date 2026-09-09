const std = @import("std");
const Allocator = std.mem.Allocator;

const PlB = @import("PlanBuilder.zig");
const Pl = @import("../Plan.zig");
const ExecNode = @import("../nodes/ExecNode.zig");

const ExecBuilder = @This();

plan: *PlB,
node: PlB.NodeIdx,

pub fn init(plan: *PlB, args: []const []const u8, env_map: ?*const std.process.Environ.Map) Allocator.Error!ExecBuilder {
    const exec_node = try ExecNode.init(plan.gpa, args, env_map);
    errdefer exec_node.asNode().deinit(plan.gpa);

    const idx = try plan.nodes.append(plan.gpa, PlB.Node{
        .interface = exec_node.asNode(),
    });
    errdefer plan.nodes.remove(idx);

    return ExecBuilder{
        .plan = plan,
        .node = idx,
    };
}

fn get(self: *const ExecBuilder) *ExecNode {
    return @ptrCast(@alignCast(self.getNode().interface.userdata));
}

fn getNode(self: *const ExecBuilder) *PlB.Node {
    return self.plan.nodes.get(self.node);
}

pub fn setEnvMap(builder: *const ExecBuilder, env_map: *const std.process.Environ.Map) Allocator.Error!void {
    const env_map_clone = try env_map.clone(builder.plan.gpa);
    return builder.setEnvMapMove(env_map_clone);
}

/// takes ownership of `env_map`
pub fn setEnvMapMove(builder: *const ExecBuilder, env_map: *const std.process.Environ.Map) void {
    const self = builder.get();

    self.env.deinit();
    self.env = env_map.*;
}

pub fn envMap(builder: *const ExecBuilder) *std.process.Environ.Map {
    return &builder.get().env;
}

pub fn addArgs(builder: *const ExecBuilder, args: []const []const u8) Allocator.Error!void {
    const self = builder.get();

    const args_slice = try self.args.addManyAsSlice(builder.plan.gpa, args.len);
    errdefer self.args.resize(self.args.items.len - args_slice.len);

    var arg_i: usize = 0;
    errdefer for (0..arg_i) |i| {
        const arg = &args_slice[i];
        arg.deinit(builder.plan.gpa);
    };
    for (args) |arg| {
        args_slice[arg_i] = ExecNode.ArgSlot{ .literal = try builder.plan.gpa.dupe(u8, arg) };
        arg_i += 1;
    }
}

pub fn getStdIn(builder: *const ExecBuilder) Allocator.Error!PlB.SinkIdx {
    const self = builder.get();
    if (self.stdin) |stdin| {
        return PlB.SinkIdx.from(stdin.value());
    }

    const idx = try builder.plan.addSink(builder.node);
    errdefer builder.plan.removeSink(idx);

    self.stdin = Pl.SinkIdx.from(idx.value());
    return idx;
}

pub fn getStdOut(builder: *const ExecBuilder) Allocator.Error!PlB.SourceIdx {
    const self = builder.get();
    if (self.stdout) |stdout| {
        return PlB.SourceIdx.from(stdout.value());
    }

    const idx = try builder.plan.addSource(builder.node);
    errdefer builder.plan.removeSource(idx);

    self.stdout = Pl.SourceIdx.from(idx.value());
    return idx;
}

pub fn getStdErr(builder: *const ExecBuilder) Allocator.Error!PlB.SourceIdx {
    const self = builder.get();
    if (self.stderr) |stderr| {
        return PlB.SourceIdx.from(stderr.value());
    }

    const idx = try builder.plan.addSource(builder.node);
    errdefer builder.plan.removeSource(idx);

    self.stderr = Pl.SourceIdx.from(idx.value());
    return idx;
}

// pub const ExecOutputAsArgError = Allocator.Error || DependOnError;

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

// pub const AddExecOutputAsArgConfig = struct {
//     stdout: bool = true,
//     stderr: bool = false,

//     trim: Plan.Sink.Data.Execution.Role.Arg.Trim = .trim_newlines,
// };
