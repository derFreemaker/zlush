const std = @import("std");
const builtin = @import("builtin");

const manifest = @import("manifest");

const Cli = @import("cli/cli.zig");

pub const Root = struct {
    version: Cli.Command(.{
        .name = "version",
        .description = "print version number and exit",
    }, void) = .{},

    help: Cli.Help = .{
        .on_empty_args = true,
    },
};

pub fn main(init: std.process.Init) !u8 {
    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const writer = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = Cli.parseArgs(Root, writer, args) catch {
        return 1;
    } orelse {
        return 0;
    };

    if (config.version.used) {
        try writer.writeAll(manifest.version);
        try writer.flush();
        return 0;
    }

    return 0;
}

test {
    _ = std.testing.refAllDecls(@This());

    return error.SkipZigTest;
}
