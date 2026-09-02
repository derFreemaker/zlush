const std = @import("std");

const Ctx = @import("Ctx.zig");

const Zlush = @This();

allocator: std.mem.Allocator,

config: Config,

env_map: std.process.Environ.Map,

pub fn init(allocator: std.mem.Allocator, env_map_: ?*const std.process.Environ.Map, config: Config) std.mem.Allocator.Error!Zlush {
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

pub fn context(self: *Zlush, allocator: std.mem.Allocator) std.mem.Allocator.Error!Ctx {
    var ctx = try Ctx.init(allocator, &self.config);
    errdefer ctx.deinit();

    return ctx;
}

pub const Config = struct {
    load_profile: bool = true,

    allow_creating_missing_directories_for_file_creation: bool = false,
};
