// const std = @import("std");

// const IndexT = @import("index.zig").IndexT;
// const Plan = @import("Plan.zig");
// const ExecIdx = Plan.ExecIdx;
// const ResolvedPlan = @import("ResolvedPlan.zig");

// const LaneIdx = IndexT(Lane, u16);

// pub fn resolve(allocator: std.mem.Allocator, plan: *const Plan) std.mem.Allocator.Error!ResolvedPlan {
//     const resolver = init(allocator, plan);
//     defer resolver.deinit();

//     var queue = try std.ArrayList(ExecIdx).initCapacity(allocator, plan.executions.items.len);
//     defer queue.deinit();
//     for (0..plan.executions.items.len) |i| {
//         queue.appendAssumeCapacity(ExecIdx.from(@intCast(i)));
//     }

//     while (queue.items.len != 0) {
//         const cur_len = queue.items.len;
//         for (0..cur_len) |i| {
//             const queue_idx = cur_len - i - 1;
//             const exec_idx = queue.items[queue_idx];

//             const resolved = try resolver.resolveExec(exec_idx);
//             if (resolved) {
//                 if (queue.items.len == 1) {
//                     _ = queue.pop();
//                 } else {
//                     _ = queue.swapRemove(queue_idx);
//                 }
//             }
//         }
//     }
// }

// const PlanResolver = @This();

// allocator: std.mem.Allocator,

// plan: *const Plan,

// lanes: std.ArrayList(Lane),
// exec_map: []?ExecMapEntry,
// tracked_files: []TrackedFile,

// fn init(allocator: std.mem.Allocator, plan: *const Plan) std.mem.Allocator.Error!PlanResolver {
//     const exec_map = try allocator.alloc(?ExecMapEntry, plan.executions.items.len);
//     errdefer allocator.free(exec_map);
//     @memset(exec_map, null);

//     const tracked_files = try allocator.alloc(TrackedFile, plan.tracked_files.items);
//     errdefer allocator.free(tracked_files);
//     @memset(tracked_files, TrackedFile{
//         .usage = .empty,
//     });

//     return PlanResolver{
//         .allocator = allocator,

//         .plan = plan,

//         .lanes = .empty,
//         .exec_map = exec_map,
//         .tracked_files = tracked_files,
//     };
// }

// fn deinit(self: *PlanResolver) void {
//     for (self.lanes.items) |*lane| {
//         lane.deinit(self.allocator);
//     }
//     self.lanes.deinit(self.allocator);

//     self.allocator.free(self.exec_map);

//     for (self.tracked_files) |*file| {
//         file.deinit(self.allocator);
//     }
//     self.allocator.free(self.tracked_files);
// }

// /// returns true or false to indicate if the execution was resolved or has a unresolved dependency
// fn resolveExec(self: *PlanResolver, exec_idx: ExecIdx) std.mem.Allocator.Error!bool {
//     const exec = self.plan.executions.items[exec_idx.value()];
//     _ = exec; // autofix

//     // const last_dep: ExecMapEntry = .{};
//     // _ = last_dep; // autofix
//     // for (exec.depends_on.items) |depend_idx| {
//     //     const dep_exec_entry = self.exec_map[depend_idx.value()] orelse return false;
//     //     if (dep_exec_entry.step > last_dep.step)
//     // }

//     @panic("unimplemented");
// }

// const TrackedFile = struct {
//     usage: std.ArrayList(usize),

//     fn deinit(self: *TrackedFile, allocator: std.mem.Allocator) void {
//         self.usage.deinit(allocator);
//     }
// };

// const Lane = struct {
//     steps: std.ArrayList(Step),

//     fn deinit(self: *Lane, allocator: std.mem.Allocator) void {
//         for (self.steps.items) |*step| {
//             step.deinit(allocator);
//         }
//     }

//     const Step = struct {
//         exec: Execution,

//         fn deinit(self: *Step, allocator: std.mem.Allocator) void {
//             self.exec.deinit(allocator);
//         }

//         const Execution = struct {
//             args: []const []const u8,
//             env_map: std.process.Environ.Map,

//             fn deinit(self: *Execution, allocator: std.mem.Allocator) void {
//                 for (self.args) |arg| {
//                     allocator.free(arg);
//                 }
//                 allocator.free(self.args);

//                 self.env_map.deinit();
//             }
//         };
//     };
// };

// const ExecMapEntry = struct {
//     lane: usize = 0,
//     step: usize = 0,
// };
