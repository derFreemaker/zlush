const std = @import("std");

const MultiReaderCircBuffer = @import("common/MultiReaderCircBuffer.zig").MultiReaderCircBuffer;
const Pl = @import("Plan.zig");

const Engine = @This();

allocator: std.mem.Allocator,
plan: *const Pl,

processes: std.ArrayList(Process),

pub fn init(self: *Engine, allocator: std.mem.Allocator, plan: *const Pl) void {
    self.allocator = allocator;
    self.plan = plan;
}

pub fn deinit(self: *Engine) void {
    _ = self; // autofix
}

pub fn execute(self: *Engine) void {
    _ = self; // autofix

}

pub const Process = struct {
    node: Pl.NodeIdx,
};

pub const Source = struct {
    node: Pl.NodeIdx,

    // @TODO: source data field

    buf: MultiReaderCircBuffer(u8),

    pub fn init(self: *Source, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        _ = self; // autofix
        _ = gpa; // autofix

    }
};
