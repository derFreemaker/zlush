const std = @import("std");

const manifest: @import("manifest.zig") = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = try std.SemanticVersion.parse(manifest.version);

    const zttio_mod = b.dependency("zttio", .{
        .target = target,
        .optimize = optimize,
    }).module("zttio");

    const zag_mod = b.dependency("zag", .{
        .target = target,
        .optimize = optimize,
    }).module("zag");

    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,

        .enabled = b.option(
            bool,
            "tracy",
            "Build with Tracy support.",
        ) orelse false,
    });
    const tracy_mod = tracy.module("tracy");

    const mod = b.addModule("zlush", .{
        .target = target,
        .optimize = optimize,

        .root_source_file = b.path("src/root.zig"),

        .imports = &.{
            .{ .name = "tracy", .module = tracy_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .optimize = optimize,
        .target = target,

        .root_source_file = b.path("src/main.zig"),

        .imports = &.{
            .{ .name = "tracy", .module = tracy_mod },

            .{ .name = "zttio", .module = zttio_mod },
            .{ .name = "zag", .module = zag_mod },

            .{ .name = "zlush", .module = mod },
        },
    });

    const manifest_options = b.addOptions();
    manifest_options.addOption([]const u8, "version", manifest.version);
    exe_mod.addOptions("manifest", manifest_options);

    const exe = b.addExecutable(.{
        .name = "zlush",
        .version = version,

        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const zlush_exe_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_tests = b.addRunArtifact(zlush_exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
