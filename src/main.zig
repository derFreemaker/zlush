const std = @import("std");
const builtin = @import("builtin");

const manifest = @import("manifest");
const zag = @import("zag");

pub const zlush = struct {
    no_profile: zag.Flag(.{
        .name = .from('p', "no-profile"),
        .description = "open zlush instance without loading the profile",
    }) = .{},

    command: zag.Option(.{
        .name = .from('c', "command"),
        .description = "command to run and exit",
    }) = .{},

    version: zag.Command(.{
        .name = "version",
        .description = "print version number and exit",
    }, void) = .{},

    _: zag.Effects = .{
        .help_on_empty_args = true,
    },
};

pub fn main(init: std.process.Init) !u8 {
    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const writer = &stdout_writer.interface;

    const args = try zag.parseArgs(zlush, writer, try init.minimal.args.toSlice(init.arena.allocator()), &.{}) orelse {
        return 1;
    };

    if (args.command.value) |command| {
        try writer.print("'{s}'\n", .{command});
        try writer.flush();
    }

    if (args.version.used) {
        try writer.writeAll(manifest.version);
        try writer.writeByte('\n');
        try writer.flush();

        return 0;
    }

    return 0;
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

test {
    @setEvalBranchQuota(2_000_000);
    refAllDeclsRecursive(@This());
}
