const std = @import("std");

const Zlush = @This();

allocator: std.mem.Allocator,
io: std.Io,

config: Config,

pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) error{OutOfMemory}!Zlush {
    return Zlush{
        .allocator = allocator,
        .io = io,

        .config = config,
    };
}

pub fn deinit(self: *Zlush) void {
    _ = self; // autofix
}

pub const Config = struct {
    load_profile: bool = true,
};

test {
    _ = @import("Tokenizer.zig");

    @setEvalBranchQuota(1_000_000);
    refAllDeclsRecursive(@This());
}

/// Given a type, recursively references all the declarations inside, so that the semantic analyzer sees them.
/// For deep types, you may use `@setEvalBranchQuota`.
pub fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);

        // @compileLog(decl, @field(T, decl.name), T);
    }
}
