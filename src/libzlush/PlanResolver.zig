const std = @import("std");

const Plan = @import("Plan.zig");
const ResolvedPlan = @import("ResolvedPlan.zig");

const PlanResolver = @This();

allocator: std.mem.Allocator,

plan: *const Plan,

lanes: std.ArrayList(Lane),

files: std.ArrayList(TrackedFile),
files_map: std.hash_map.StringHashMapUnmanaged(usize),

pub fn init(allocator: std.mem.Allocator, plan: *const Plan) PlanResolver {
    return PlanResolver{
        .allocator = allocator,

        .plan = plan,

        .lanes = .empty,

        .files = .empty,
        .files_map = .empty,
    };
}

pub fn deinit(self: *PlanResolver) void {
    for (self.lanes.items) |*lane| {
        lane.deinit(self.allocator);
    }
    self.lanes.deinit(self.allocator);

    for (self.files.items) |*file| {
        file.deinit(self.allocator);
    }
    self.files.deinit(self.allocator);
    self.files_map.deinit(self.allocator);
}

pub fn resolve(self: *const PlanResolver, allocator: std.mem.Allocator) ResolvedPlan {
    _ = self; // autofix
    _ = allocator; // autofix

    @panic("unimplemented");
}

pub const TrackedFile = struct {
    usage: std.ArrayList(usize),

    fn deinit(self: *TrackedFile, allocator: std.mem.Allocator) void {
        self.usage.deinit(allocator);
    }
};

pub const Lane = struct {
    steps: std.ArrayList(Step),

    fn deinit(self: *Lane, allocator: std.mem.Allocator) void {
        for (self.steps.items) |*step| {
            step.deinit(allocator);
        }
    }

    pub const Step = struct {
        execution: Execution,

        fn deinit(self: *Step, allocator: std.mem.Allocator) void {
            self.execution.deinit(allocator);
        }

        pub const Execution = struct {
            args: []const []const u8,
            env_map: std.process.Environ.Map,

            fn deinit(self: *Execution, allocator: std.mem.Allocator) void {
                for (self.args) |arg| {
                    allocator.free(arg);
                }
                allocator.free(self.args);

                self.env_map.deinit();
            }
        };
    };
};
