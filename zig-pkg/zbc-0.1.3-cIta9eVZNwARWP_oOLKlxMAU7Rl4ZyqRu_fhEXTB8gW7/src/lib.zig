//! Public library API for the zbc escape analyzer.

const std = @import("std");
const Ast = std.zig.Ast;

const cfg_mod = @import("flow/cfg.zig");
const cfg_builder = @import("flow/cfg_builder.zig");
const worklist = @import("flow/worklist.zig");
const config_mod = @import("config.zig");
const problem_mod = @import("problem.zig");
const rule_catalog_mod = @import("rule_catalog.zig");
const file_cache_mod = @import("cache/file_cache.zig");
const suppressions_mod = @import("suppressions.zig");
const zls_resolver_mod = @import("type_resolver.zig");
const project_cache_mod = @import("cache/project_cache.zig");

pub const Config = config_mod.Config;
pub const DefaultConfig = config_mod.Default;
pub const Invariant = config_mod.Invariant;
pub const all_invariants = config_mod.all_invariants;
pub const isEnabled = config_mod.isEnabled;
pub const invariantFromName = config_mod.invariantFromName;
pub const Problem = problem_mod.Problem;
pub const Note = problem_mod.Note;
pub const Pos = problem_mod.Pos;
pub const Severity = problem_mod.Severity;
pub const Rule = rule_catalog_mod.Rule;
pub const rule_catalog = rule_catalog_mod.all;
pub const lookupRule = rule_catalog_mod.lookup;
pub const trace = @import("trace.zig");
pub fn analyzeEscape(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    config: *const Config,
    type_ctx: ?*zls_resolver_mod.TypeContext,
) ![]Problem {
    trace.setFile(path);
    const src_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(src_bytes);

    const src = try gpa.allocSentinel(u8, src_bytes.len, 0);
    defer gpa.free(src);
    @memcpy(src[0..src_bytes.len], src_bytes);
    rewriteNonStandardSyntax(src);

    var tree = try Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);

    var problems: std.ArrayListUnmanaged(Problem) = .empty;
    errdefer freeProblemsArrayList(gpa, &problems);

    // Type resolver backed by the extracted type engine.  TypeContext is
    // per-thread (see main.zig workerLoop); falls through to AST-only
    // analysis when unavailable or when init fails.
    var own_ctx: zls_resolver_mod.ManagedContext = .{};
    if (type_ctx == null) own_ctx.tryInit(gpa, io);
    defer own_ctx.deinit();
    const ctx = type_ctx orelse own_ctx.get();

    var own_resolver: zls_resolver_mod.ManagedResolver = .{};
    if (ctx) |c| own_resolver.tryInit(c, gpa, path, src);
    defer own_resolver.deinit();
    const zls_ptr = own_resolver.get();

    // Per-file shared cache, used by both flow analysis (cfg) and
    // pattern rules.  Amortizes FileModel + LocalBindings + FnSummary
    // across every consumer.
    var rule_cache = file_cache_mod.FileCache.init(gpa, &tree);
    defer rule_cache.deinit();
    rule_cache.setZls(zls_ptr);
    // Project-wide ProjectCache for cross-file model lookups via
    // relative `@import("./X.zig")` declarations.  Static across
    // the process so subsequent analyzeEscape calls reuse the
    // loaded models — saves re-parsing the same shared headers
    // across every file in a sweep.
    rule_cache.setProject(getProjectCache(gpa, io), path);
    try rule_cache.resolveTransitiveTakes();

    // Flow analysis — per-fn CFG + worklist fixed-point.
    // Iterate raw fn_decls (incl. type-builders) — lowerFunctionFull
    // decides per-fn whether to lower (returns null to skip).
    var node_idx: u32 = 1;
    while (node_idx < tree.nodes.len) : (node_idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_idx);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var cfg = (try cfg_builder.lowerFunctionFullWithZls(
            gpa,
            &tree,
            node,
            config,
            &rule_cache,
            zls_ptr,
        )) orelse continue;
        defer cfg.deinit(gpa);
        try worklist.check(gpa, &cfg, .{ .path = path, .config = config }, &problems);
    }

    // Pattern detectors — dispatched via the comptime registry so
    // adding a rule is a one-file change (see rule_catalog.zig).
    try rule_catalog_mod.runEscape(gpa, &tree, &rule_cache, config, &problems);

    // Apply per-line suppressions parsed from `// zbc-disable-line` /
    // `// zbc-disable-next-line` source comments.  Filter happens at
    // the boundary so individual rules don't need to know about it.
    var supp = try suppressions_mod.parse(gpa, src);
    defer supp.deinit();
    return try filterSuppressed(gpa, &problems, &supp);
}

/// Bun's codebase uses a non-standard `fn #<name>(...)` method-name
/// syntax (their build pipeline preprocesses it).  The stock Zig
/// tokenizer chokes on `#` and emits `invalid` tokens, which causes
/// the AST past the first such fn to be lost — entire types appear
/// to have no methods, masking real cleanup methods like `finalize`
/// and producing cascades of FPs (missing-deinit, owned-field-no-
/// outer-cleanup, etc.) on every file that touches the pattern.
///
/// Workaround: in-place byte-level rewrite of `fn #` → `fn _` and
/// `.#<ident>(` → `._<ident>(` (call-site form).  Both replacements
/// are length-preserving so source positions remain stable.
/// Replacing only after `fn ` or `.` avoids touching `#`-containing
/// string literals or comments that happen to start a line.
fn rewriteNonStandardSyntax(src: [:0]u8) void {
    if (src.len < 2) return;
    // `#` is not a valid token start in Zig 0.17.  Bun uses it as
    // a private-name prefix in three positions:
    //   1. method decls:  `fn #foo(...)`
    //   2. field decls:   `#foo: Foo = .{}`
    //   3. accesses:      `this.#foo` / `this.#foo()`
    // In all three, `#` is immediately followed by an identifier
    // character (letter or `_`).  Rewriting `#<id-char>` → `_<id-char>`
    // covers all three positions and is length-preserving.  The only
    // false-positive is a `#` inside a STRING LITERAL whose next char
    // is a letter — but the analyzer doesn't track string CONTENTS,
    // so it's harmless.
    var i: usize = 0;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] != '#') continue;
        const next = src[i + 1];
        if (isIdentStart(next)) src[i] = '_';
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

/// Drop any Problems whose start.line matches an active suppression.
/// Frees dropped problems immediately; the caller still owns the
/// returned slice and the surviving problems' message storage.
fn filterSuppressed(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    supp: *const suppressions_mod.Suppressions,
) ![]Problem {
    if (supp.entries.len == 0) return problems.toOwnedSlice(gpa);
    var kept: std.ArrayListUnmanaged(Problem) = .empty;
    errdefer freeProblemsArrayList(gpa, &kept);
    for (problems.items) |p| {
        if (supp.isSuppressed(p.rule_id, p.start.line)) {
            var dead = p;
            dead.deinit(gpa);
            continue;
        }
        try kept.append(gpa, p);
    }
    problems.deinit(gpa);
    return kept.toOwnedSlice(gpa);
}

/// Process-static ProjectCache.  Holds parsed FileModels for
/// sibling `.zig` files reached via relative `@import("./X.zig")`
/// declarations.  Initialised on first analyzeEscape call,
/// persists for the process lifetime — multi-file sweeps reuse
/// the loaded models.  Lives on the heap (page_allocator) so test
/// gpa boundaries don't reclaim it.
var global_project: ?*project_cache_mod.ProjectCache = null;

fn getProjectCache(gpa: std.mem.Allocator, io: std.Io) *project_cache_mod.ProjectCache {
    _ = gpa;
    if (global_project) |p| return p;
    const pa = std.heap.page_allocator;
    const p = pa.create(project_cache_mod.ProjectCache) catch unreachable;
    p.* = project_cache_mod.ProjectCache.init(pa, io);
    global_project = p;
    return p;
}

/// Test-only: clear the process-static project cache so leak
/// detectors don't see the cached entries between test gpas.
pub fn clearProjectCacheForTesting() void {
    if (global_project) |p| {
        p.deinit();
        std.heap.page_allocator.destroy(p);
        global_project = null;
    }
}

pub fn freeProblems(gpa: std.mem.Allocator, slice: []Problem) void {
    for (slice) |*p| p.deinit(gpa);
    gpa.free(slice);
}

fn freeProblemsArrayList(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(Problem)) void {
    for (list.items) |*p| p.deinit(gpa);
    list.deinit(gpa);
}

// ── Tests ───────────────────────────────────────────────────────

test "lib API: analyzeEscape end-to-end flags arena escape" {
    const gpa = std.testing.allocator;
    const tio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tio, .{ .sub_path = "foo.zig", .data =
        \\const std = @import("std");
        \\const Arena = struct {
        \\    inner: std.heap.ArenaAllocator,
        \\    bytes: []const u8 = "",
        \\    pub fn text(self: *const Arena) []const u8 { return self.bytes; }
        \\};
        \\pub fn foo() []const u8 {
        \\    var arena = Arena{ .inner = std.heap.ArenaAllocator.init(undefined) };
        \\    return arena.text();
        \\}
        \\
    });

    const base_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base_dir);
    const path = try std.fs.path.join(gpa, &.{ base_dir, "foo.zig" });
    defer gpa.free(path);

    const problems = try analyzeEscape(gpa, tio, path, &DefaultConfig, null);
    defer freeProblems(gpa, problems);

    var found = false;
    for (problems) |p| {
        if (std.mem.indexOf(u8, p.message, "function-local arena") != null) found = true;
    }
    try std.testing.expect(found);
}

// ── Suppression integration tests ───────────────────────────────
//
// These tests run the full analyzeEscape pipeline on real files to
// verify that filterSuppressed correctly removes or keeps problems
// based on // zbc-disable-line / // zbc-disable-next-line directives.
// They use ptrfromint-zero as the trigger — easy to place and the
// finding lands on a predictable source line.

fn analyzeSrc(
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    src: []const u8,
) ![]Problem {
    const name = "check.zig";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = src });
    const base_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base_dir);
    const path = try std.fs.path.join(gpa, &.{ base_dir, name });
    defer gpa.free(path);
    return analyzeEscape(gpa, io, path, &DefaultConfig, null);
}

fn countByRule(problems: []const Problem, rule_id: []const u8) usize {
    var n: usize = 0;
    for (problems) |p| {
        if (std.mem.eql(u8, p.rule_id, rule_id)) n += 1;
    }
    return n;
}

test "suppression: zbc-disable-line drops the finding on the same line" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Without directive: @ptrFromInt(0) on line 2 → 1 problem.
    // With directive on the same line: 0 problems.
    const problems = try analyzeSrc(gpa, std.testing.io, &tmp,
        \\fn zero_ptr() *anyopaque {
        \\    return @ptrFromInt(0); // zbc-disable-line: ptrfromint-zero
        \\}
        \\
    );
    defer freeProblems(gpa, problems);
    try std.testing.expectEqual(@as(usize, 0), countByRule(problems, "ptrfromint-zero"));
}

test "suppression: without directive the finding is not dropped" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const problems = try analyzeSrc(gpa, std.testing.io, &tmp,
        \\fn zero_ptr() *anyopaque {
        \\    return @ptrFromInt(0);
        \\}
        \\
    );
    defer freeProblems(gpa, problems);
    try std.testing.expect(countByRule(problems, "ptrfromint-zero") >= 1);
}

test "suppression: zbc-disable-next-line drops the finding on the following line" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const problems = try analyzeSrc(gpa, std.testing.io, &tmp,
        \\fn zero_ptr() *anyopaque {
        \\    // zbc-disable-next-line: ptrfromint-zero
        \\    return @ptrFromInt(0);
        \\}
        \\
    );
    defer freeProblems(gpa, problems);
    try std.testing.expectEqual(@as(usize, 0), countByRule(problems, "ptrfromint-zero"));
}

test "suppression: wildcard zbc-disable-line: * drops any rule" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const problems = try analyzeSrc(gpa, std.testing.io, &tmp,
        \\fn zero_ptr() *anyopaque {
        \\    return @ptrFromInt(0); // zbc-disable-line: *
        \\}
        \\
    );
    defer freeProblems(gpa, problems);
    try std.testing.expectEqual(@as(usize, 0), countByRule(problems, "ptrfromint-zero"));
}

test "suppression: wrong rule id leaves the finding" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Directive targets a different rule → ptrfromint-zero still fires.
    const problems = try analyzeSrc(gpa, std.testing.io, &tmp,
        \\fn zero_ptr() *anyopaque {
        \\    return @ptrFromInt(0); // zbc-disable-line: some-other-rule
        \\}
        \\
    );
    defer freeProblems(gpa, problems);
    try std.testing.expect(countByRule(problems, "ptrfromint-zero") >= 1);
}

test "suppression: directive only suppresses its own line, not others" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two @ptrFromInt(0) calls on different lines.
    // Only the first has a directive — second still fires.
    const problems = try analyzeSrc(gpa, std.testing.io, &tmp,
        \\fn a() *anyopaque {
        \\    return @ptrFromInt(0); // zbc-disable-line: ptrfromint-zero
        \\}
        \\fn b() *anyopaque {
        \\    return @ptrFromInt(0);
        \\}
        \\
    );
    defer freeProblems(gpa, problems);
    try std.testing.expectEqual(@as(usize, 1), countByRule(problems, "ptrfromint-zero"));
}

test {
    _ = cfg_mod;
    _ = worklist;
    _ = config_mod;
    _ = problem_mod;
    _ = @import("flow/abstract_state.zig");
    _ = @import("flow/cfg_transfer.zig");
    _ = @import("flow/value_range.zig");
    // Pattern rules are registered in rule_catalog_mod alongside the
    // catalog metadata; pulling it in refAllDecls'es every rule
    // module so inline tests run.
    _ = rule_catalog_mod;
    _ = file_cache_mod;
    _ = suppressions_mod;
    _ = @import("model/fn_summary.zig");
    _ = @import("type_resolver.zig");
    _ = @import("ast/tokens.zig");
    _ = @import("ast/scope_iter.zig");
    _ = @import("model/method_names.zig");
    _ = @import("testing.zig");
    _ = @import("model/file_model.zig");
    _ = @import("trace.zig");
    _ = @import("model/local_bindings.zig");
    _ = @import("ast/token_query.zig");
    _ = @import("model/model_query.zig");
    _ = @import("cache/project_cache.zig");
    std.testing.refAllDecls(@This());
}
