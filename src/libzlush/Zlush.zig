const std = @import("std");
const Allocator = std.mem.Allocator;

const PlB = @import("builder/PlanBuilder.zig");

const Zlush = @This();

allocator: Allocator,

config: Config,

env_map: std.process.Environ.Map,

pub fn init(allocator: Allocator, env_map_: ?*const std.process.Environ.Map, config: Config) Allocator.Error!Zlush {
    var env_map = if (env_map_) |env_map|
        try env_map.clone(allocator)
    else
        std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();

    return Zlush{
        .allocator = allocator,

        .config = config,

        .env_map = env_map,
    };
}

pub fn deinit(self: *Zlush) void {
    self.env_map.deinit();
}

pub fn builder(self: *Zlush, gpa: Allocator) Allocator.Error!PlB {
    var b: PlB = undefined;
    try PlB.init(&b, gpa, &self.config);
    errdefer b.deinit();

    return b;
}

pub const Config = struct {
    load_profile: bool = true,

    allow_creating_missing_directories_for_file_creation: bool = false,
};
