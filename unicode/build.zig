const std = @import("std");

pub fn buildGBPTables(b: *std.Build) std.Build.LazyPath {
    const gbp_gen_exe = b.addExecutable(.{
        .name = "gbp",

        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,

            .root_source_file = b.path("unicode/gbp.zig"),
        }),
    });
    gbp_gen_exe.root_module.addAnonymousImport("DerivedCoreProperties.txt", .{ .root_source_file = b.path("unicode/data/DerivedCoreProperties.txt") });
    gbp_gen_exe.root_module.addAnonymousImport("GraphemeBreakProperty.txt", .{ .root_source_file = b.path("unicode/data/auxiliary/GraphemeBreakProperty.txt") });
    gbp_gen_exe.root_module.addAnonymousImport("emoji-data.txt", .{ .root_source_file = b.path("unicode/data/emoji/emoji-data.txt") });

    const run_gbp_gen_exe = b.addRunArtifact(gbp_gen_exe);
    const gbp_gen_out = run_gbp_gen_exe.addOutputFileArg("gbp.bin.z");

    return gbp_gen_out;
}

pub fn buildDWPTables(b: *std.Build, dwp_options: *std.Build.Step.Options) std.Build.LazyPath {
    const dwp_gen_exe = b.addExecutable(.{
        .name = "dwp",

        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,

            .root_source_file = b.path("unicode/dwp.zig"),
        }),
    });
    dwp_gen_exe.root_module.addAnonymousImport("DerivedEastAsianWidth.txt", .{ .root_source_file = b.path("unicode/data/extracted/DerivedEastAsianWidth.txt") });
    dwp_gen_exe.root_module.addAnonymousImport("DerivedGeneralCategory.txt", .{ .root_source_file = b.path("unicode/data/extracted/DerivedGeneralCategory.txt") });
    dwp_gen_exe.root_module.addOptions("options", dwp_options);

    const run_dwp_gen_exe = b.addRunArtifact(dwp_gen_exe);
    const dwp_gen_out = run_dwp_gen_exe.addOutputFileArg("dwp.bin.z");

    return dwp_gen_out;
}
