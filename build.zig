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

    const tracy = Tracy.init(b, .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("zlush", .{
        .target = target,
        .optimize = optimize,

        .root_source_file = b.path("src/root.zig"),
    });
    tracy.importFor(mod);

    const exe_mod = b.createModule(.{
        .optimize = optimize,
        .target = target,

        .root_source_file = b.path("src/main.zig"),

        .imports = &.{
            .{ .name = "zttio", .module = zttio_mod },

            .{ .name = "zlush", .module = mod },
        },
    });
    tracy.importFor(exe_mod);
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

pub const Tracy = struct {
    dependecy: *std.Build.Dependency,
    enabled: bool,

    pub fn init(b: *std.Build, args: anytype) Tracy {
        const enabled = b.option(
            bool,
            "tracy",
            "Build with Tracy support.",
        ) orelse false;

        const tracy = b.dependency("tracy", args);

        return Tracy{
            .dependecy = tracy,
            .enabled = enabled,
        };
    }

    pub fn importFor(self: *const Tracy, module: *std.Build.Module) void {
        module.addImport("tracy", self.dependecy.module("tracy"));
        if (self.enabled) {
            module.addImport("tracy_impl", self.dependecy.module("tracy_impl_enabled"));
        } else {
            module.addImport("tracy_impl", self.dependecy.module("tracy_impl_disabled"));
        }
    }
};
