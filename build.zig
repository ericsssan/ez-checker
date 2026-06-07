const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const es_parser_dep = b.dependency("es_parser", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const es_parser_mod = es_parser_dep.module("es-parser");

    const mod = b.addModule("ez-checker", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("es_parser", es_parser_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("es_parser", es_parser_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Oracle: ez-checker's conformance test suite against the TypeScript corpus.
    // One file (oracle.zig, at the project root so @embedFile can reach oracle/)
    // is the root of BOTH a test and an executable:
    //   zig build test-oracle  — the ratcheting regression gate (its `test` blocks)
    //   zig build run-oracle    — the same sweep as a report-printing executable
    const oracle_test_mod = b.createModule(.{
        .root_source_file = b.path("oracle.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_test_mod.addImport("es_parser", es_parser_mod);
    oracle_test_mod.addImport("ez_checker", mod);
    const oracle_tests = b.addTest(.{ .root_module = oracle_test_mod });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_step = b.step("test-oracle", "Run the TypeScript-corpus conformance gate");
    oracle_step.dependOn(&run_oracle_tests.step);

    const oracle_exe_mod = b.createModule(.{
        .root_source_file = b.path("oracle.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_exe_mod.addImport("es_parser", es_parser_mod);
    oracle_exe_mod.addImport("ez_checker", mod);
    const oracle_exe = b.addExecutable(.{
        .name = "oracle",
        .root_module = oracle_exe_mod,
    });
    b.installArtifact(oracle_exe);
    const run_oracle = b.addRunArtifact(oracle_exe);
    const run_oracle_step = b.step("run-oracle", "Sweep the TypeScript corpus and report conformance");
    run_oracle_step.dependOn(&run_oracle.step);

    // Regenerate the ratchet baseline from the current numbers (never hand-edited).
    const save_baseline = b.addRunArtifact(oracle_exe);
    save_baseline.addArg("--save-baseline");
    const save_baseline_step = b.step("save-baseline", "Overwrite oracle/baseline.lock with the current conformance numbers");
    save_baseline_step.dependOn(&save_baseline.step);
}
