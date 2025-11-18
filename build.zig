const std = @import("std");
const manifest: @import("src/common/manifest.zig") = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = try std.SemanticVersion.parse(manifest.version);

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,

        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
        }),
    });

    const common_mod = b.addModule("common", .{
        .target = target,
        .optimize = optimize,

        .root_source_file = b.path("src/common/common.zig"),

        .imports = &.{
            .{
                .name = "zon",
                .module = b.createModule(.{
                    .root_source_file = b.path("build.zig.zon"),
                }),
            },
            .{ .name = "uucode", .module = uucode_dep.module("uucode") },
        },
    });

    const zlush_mod = b.addModule("zlush", .{
        .target = target,
        .optimize = optimize,

        .root_source_file = b.path("src/root.zig"),

        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const zlush_exe = b.addExecutable(.{
        .name = "zlush",
        .version = version,

        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,

            .root_source_file = b.path("src/main.zig"),

            .imports = &.{
                .{ .name = "common", .module = common_mod },

                .{ .name = "zlush", .module = zlush_mod },
            },
        }),
    });
    zlush_exe.linkLibC();
    b.installArtifact(zlush_exe);

    // Tracy
    {
        const tracy_enabled = b.option(
            bool,
            "tracy",
            "Build with Tracy support.",
        ) orelse false;

        const tracy = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
        });

        zlush_exe.root_module.addImport("tracy", tracy.module("tracy"));
        if (tracy_enabled) {
            zlush_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
        } else {
            zlush_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
        }
    }

    const common_mod_tests = b.addTest(.{
        .root_module = common_mod,
    });
    const run_common_mod_tests = b.addRunArtifact(common_mod_tests);

    const zlush_mod_tests = b.addTest(.{
        .root_module = zlush_mod,
    });
    const run_zlush_mod_tests = b.addRunArtifact(zlush_mod_tests);

    const zlush_exe_tests = b.addTest(.{
        .root_module = zlush_exe.root_module,
    });
    const run_zlush_exe_tests = b.addRunArtifact(zlush_exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_common_mod_tests.step);
    test_step.dependOn(&run_zlush_mod_tests.step);
    test_step.dependOn(&run_zlush_exe_tests.step);
}
