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

    const debug_mod = b.createModule(.{
        .root_source_file = b.path("src/debug_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mod.addImport("es_parser", es_parser_mod);
    debug_mod.addImport("ez_checker", mod);
    const debug_tests = b.addTest(.{ .root_module = debug_mod });
    const run_debug = b.addRunArtifact(debug_tests);
    const debug_step = b.step("test-debug", "Run debug test");
    debug_step.dependOn(&run_debug.step);

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
    const install_oracle = b.addInstallArtifact(oracle_exe, .{});
    b.getInstallStep().dependOn(&install_oracle.step);
    const run_oracle = b.addRunArtifact(oracle_exe);
    // Always install (sync zig-out/bin/oracle) before running so that manual
    // `zig-out/bin/oracle --trace ...` invocations never see a stale binary.
    run_oracle.step.dependOn(&install_oracle.step);
    const run_oracle_step = b.step("run-oracle", "Sweep the TypeScript corpus and report conformance");
    run_oracle_step.dependOn(&run_oracle.step);

    // Regenerate the ratchet baseline from the current numbers (never hand-edited).
    const save_baseline = b.addRunArtifact(oracle_exe);
    save_baseline.step.dependOn(&install_oracle.step);
    save_baseline.addArg("--save-baseline");
    const save_baseline_step = b.step("save-baseline", "Overwrite oracle/baseline.lock with the current conformance numbers");
    save_baseline_step.dependOn(&save_baseline.step);

    // oracle-snapshot: write per-expression TSV for later diffing.
    //   zig build oracle-snapshot -- out.tsv
    const oracle_snapshot = b.addRunArtifact(oracle_exe);
    oracle_snapshot.addArg("--snapshot");
    oracle_snapshot.addPassthruArgs();
    const oracle_snapshot_step = b.step("oracle-snapshot", "Write per-expression snapshot TSV (zig build oracle-snapshot -- out.tsv)");
    oracle_snapshot_step.dependOn(&oracle_snapshot.step);

    // oracle-diff: compare two snapshots offline.
    //   zig build oracle-diff -- before.tsv after.tsv
    const oracle_diff = b.addRunArtifact(oracle_exe);
    oracle_diff.addArg("--diff");
    oracle_diff.addPassthruArgs();
    const oracle_diff_step = b.step("oracle-diff", "Diff two snapshot TSVs (zig build oracle-diff -- before.tsv after.tsv)");
    oracle_diff_step.dependOn(&oracle_diff.step);

    // oracle-dump: per-expression side-by-side dump for one file pattern.
    //   zig build oracle-dump -- somePattern
    const oracle_dump = b.addRunArtifact(oracle_exe);
    oracle_dump.addArg("--dump");
    oracle_dump.addPassthruArgs();
    const oracle_dump_step = b.step("oracle-dump", "Per-expression tsc vs ez dump for a file pattern (zig build oracle-dump -- pattern)");
    oracle_dump_step.dependOn(&oracle_dump.step);

    // oracle-trace: show all sibling expressions on the same source line.
    //   zig build oracle-trace -- "expr_text"
    //   zig build oracle-trace -- "expr_text" --filter file_pattern
    const oracle_trace = b.addRunArtifact(oracle_exe);
    oracle_trace.addArg("--trace");
    oracle_trace.addPassthruArgs();
    const oracle_trace_step = b.step("oracle-trace", "Trace expr across corpus: all siblings on same source line (zig build oracle-trace -- \"expr\")");
    oracle_trace_step.dependOn(&oracle_trace.step);

    // oracle-diff-cat: diff with category drilldown.
    //   zig build oracle-diff-cat -- before.tsv after.tsv --cat correct wrong --got-contains typeof
    const oracle_diff_cat = b.addRunArtifact(oracle_exe);
    oracle_diff_cat.addArg("--diff-cat");
    oracle_diff_cat.addPassthruArgs();
    const oracle_diff_cat_step = b.step("oracle-diff-cat", "Diff drilldown by category (zig build oracle-diff-cat -- before.tsv after.tsv [--cat c w] [--got str])");
    oracle_diff_cat_step.dependOn(&oracle_diff_cat.step);

    // oracle-filter-snap: snapshot just files matching a pattern.
    //   zig build oracle-filter-snap -- pattern out.tsv
    const oracle_filter_snap = b.addRunArtifact(oracle_exe);
    oracle_filter_snap.addArg("--filter-snap");
    oracle_filter_snap.addPassthruArgs();
    const oracle_filter_snap_step = b.step("oracle-filter-snap", "Snapshot files matching pattern (zig build oracle-filter-snap -- pattern out.tsv)");
    oracle_filter_snap_step.dependOn(&oracle_filter_snap.step);

    // Fuzz smoke test — runs each seed once under the normal test runner.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("es_parser", es_parser_mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // `zig build fuzz` — stdin-reading binary for AFL++ / honggfuzz.
    //
    // Quick start:
    //   zig build fuzz
    //   mkdir -p corpus && cp src/fuzz.zig corpus/  # bootstrap seed
    //   afl-fuzz -i corpus/ -o findings/ -- ./zig-out/bin/fuzz-ez
    const fuzz_step = b.step("fuzz", "Build AFL++/honggfuzz stdin fuzz target");
    const fuzz_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = .Debug,
    });
    fuzz_exe_mod.addImport("es_parser", es_parser_mod);
    const fuzz_exe = b.addExecutable(.{ .name = "fuzz-ez", .root_module = fuzz_exe_mod });
    b.installArtifact(fuzz_exe);
    fuzz_step.dependOn(&b.addInstallArtifact(fuzz_exe, .{}).step);

    // zbc: run the Zig bug checker over src/.
    const zbc_dep = b.dependency("zbc", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const zbc_exe = zbc_dep.artifact("zbc");
    const run_zbc = b.addRunArtifact(zbc_exe);
    run_zbc.addDirectoryArg(b.path("src"));
    const zbc_step = b.step("zbc", "Run zbc bug checker on src/");
    zbc_step.dependOn(&run_zbc.step);
    b.default_step.dependOn(&run_zbc.step);
}
