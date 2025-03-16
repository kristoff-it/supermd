const std = @import("std");
pub const Ast = struct {};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scripty = b.dependency("scripty", .{});
    const superhtml = b.dependency("superhtml", .{});
    const ziggy = b.dependency("ziggy", .{}).module("ziggy");
    const gfm = b.dependency("gfm", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = b.option(
            bool,
            "sanitize-thread",
            "enable thread sanitizer for cmark-gfm",
        ) orelse (optimize == .Debug),
    });

    const supermd = b.addModule("supermd", .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = true,
    });

    supermd.addImport("scripty", scripty.module("scripty"));
    supermd.addImport("superhtml", superhtml.module("superhtml"));
    supermd.addImport("ziggy", ziggy);
    supermd.linkLibrary(gfm.artifact("cmark-gfm"));
    supermd.linkLibrary(gfm.artifact("cmark-gfm-extensions"));

    const docgen = b.addExecutable(.{
        .name = "docgen",
        .root_source_file = b.path("src/docgen.zig"),
        .target = target,
        .optimize = optimize,
    });

    docgen.root_module.addImport("ziggy", ziggy);

    b.installArtifact(docgen);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("scripty", scripty.module("scripty"));
    unit_tests.root_module.addImport("superhtml", superhtml.module("superhtml"));
    unit_tests.root_module.addImport("ziggy", ziggy);
    unit_tests.root_module.linkLibrary(gfm.artifact("cmark-gfm"));
    unit_tests.root_module.linkLibrary(gfm.artifact("cmark-gfm-extensions"));
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const check_step = b.step("check", "Check the project");
    check_step.dependOn(&run_unit_tests.step);
}
