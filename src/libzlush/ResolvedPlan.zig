const std = @import("std");

const ResolvedPlan = @This();

lanes: []const Lane,

pub fn deinit(self: *ResolvedPlan) void {
    _ = self; // autofix
}

pub const Lane = struct { actions: std.ArrayList };
