const std = @import("std");
const Allocator = std.mem.Allocator;

const Pl = @import("../Plan.zig");

const ExecNode = @This();

args: std.ArrayList(ArgSlot) = .empty,
env: std.process.Environ.Map,

stdin: ?Pl.SinkIdx,
stdout: ?Pl.SourceIdx,
stderr: ?Pl.SourceIdx,

pub fn init(gpa: Allocator, args: []const []const u8, env_map: ?*const std.process.Environ.Map) Allocator.Error!*ExecNode {
    const self = try gpa.create(ExecNode);
    errdefer gpa.destroy(self);

    self.env = if (env_map) |env| try env.clone(gpa) else std.process.Environ.Map.init(gpa);
    errdefer self.env.deinit();

    self.args = try .initCapacity(gpa, args.len);
    errdefer {
        for (self.args.items) |*arg| {
            arg.deinit(gpa);
        }
        self.args.deinit(gpa);
    }
    for (args) |arg| {
        self.args.appendAssumeCapacity(.{ .literal = try gpa.dupe(u8, arg) });
    }

    self.stdin = null;
    self.stdout = null;
    self.stderr = null;

    return self;
}

pub fn asNode(self: *ExecNode) Pl.Node.Interface {
    return Pl.Node.Interface{
        .userdata = self,
        .vtable = &.{
            .deinit = deinit,
            .clone = clone,

            .spawn = spawn,
            .cleanup = cleanup,

            .tick = tick,
        },
    };
}

fn deinit(userdata: *anyopaque, gpa: Allocator) void {
    const self: *ExecNode = @ptrCast(@alignCast(userdata));
    defer gpa.destroy(self);

    for (self.args.items) |*arg| {
        arg.deinit(gpa);
    }
    self.args.deinit(gpa);

    self.env.deinit();
}

fn clone(userdata: *anyopaque, gpa: Allocator) Allocator.Error!*anyopaque {
    const self: *ExecNode = @ptrCast(@alignCast(userdata));

    const copy = try gpa.create(ExecNode);
    errdefer gpa.destroy(copy);

    var arg_i: usize = 0;
    copy.args = try .initCapacity(gpa, self.args.items.len);
    errdefer {
        for (copy.args.items) |*arg| {
            arg.deinit(gpa);
        }
        copy.args.deinit(gpa);
    }
    for (self.args.items) |arg| {
        switch (arg) {
            .literal => |literal| copy.args.appendAssumeCapacity(ArgSlot{
                .literal = try gpa.dupe(u8, literal),
            }),

            .captured => |captured| copy.args.appendAssumeCapacity(ArgSlot{
                .captured = Pl.SinkIdx.from(captured.value()),
            }),

            .start_concat,
            .end_concat,
            => copy.args.appendAssumeCapacity(arg),
        }

        arg_i += 1;
    }

    copy.env = try self.env.clone(gpa);
    errdefer copy.env.deinit();

    copy.stdin = self.stdin;
    copy.stdout = self.stdout;
    copy.stderr = self.stderr;

    return copy;
}

fn spawn(userdata: *anyopaque, gpa: Allocator) Allocator.Error!*anyopaque {
    _ = userdata; // autofix
    _ = gpa; // autofix
    return undefined;
}

fn cleanup(userdata: *anyopaque, instance: *anyopaque, gpa: Allocator) void {
    _ = userdata; // autofix
    _ = instance; // autofix
    _ = gpa; // autofix
}

fn tick(userdata: *anyopaque, instance: *anyopaque, ctx: *Pl.EngineContext) Allocator.Error!Pl.Node.TickResult {
    _ = userdata; // autofix
    _ = instance; // autofix
    _ = ctx; // autofix
    return .done;
}

pub const ArgSlot = union(enum) {
    literal: []const u8,
    captured: Pl.SinkIdx,
    start_concat,
    end_concat,

    pub fn deinit(self: *ArgSlot, gpa: Allocator) void {
        switch (self.*) {
            .literal => |literal| gpa.free(literal),
            else => {},
        }
    }
};
