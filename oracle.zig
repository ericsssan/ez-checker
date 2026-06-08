// ez-checker oracle — validated against the TypeScript compiler's own test
// corpus, treating tsc as the ground-truth oracle (the same corpus TypeScript
// uses to test itself). This one file is both:
//
//   * the test suite   — `zig build test-oracle` runs the `test` block below.
//                         It sweeps EVERY section of EVERY `.types` baseline in
//                         the vendored submodule, compares ez-checker's inferred
//                         type for every expression against tsc's, and FAILS the
//                         build if conformance regresses below the committed
//                         ratchet (oracle/baseline.lock).
//
//   * the executable   — `zig build run-oracle` runs `main()`, doing the same
//                         sweep and printing the same full report.
//
// Honesty is the point: nothing relevant is silently skipped, and the report is
// verbose by default. Multi-section baselines are evaluated as a single program
// (cross-file types resolve correctly). Every baseline expression lands in
// exactly one reported bucket — correct / wrong / coverage-gap / no-node — so
// the denominator can't be shrunk to flatter the rate. The breakdown tables
// cover ALL expression types (not just primitives), grouped by tsc category →
// ez category with a concrete example per row.
//
// Anchoring strategy (why this is robust):
//   A `.types` section interleaves each source line with `>expr : type` entries
//   for the expressions starting on that line. We collect the non-`>` lines as
//   the "effective source" — *exactly* the text the baseline's expr fragments
//   were sliced from — so parsing it aligns AST node line-numbers and node
//   source-text with the baseline with zero realignment. Each entry's type
//   boundary is the decoration line's first `^` column (the only reliable
//   expr/type split, since both exprs and types can contain " : ").
//
// Compiler options (fix #2):
//   Each .types file's header encodes the source path. We read that file and
//   parse its `// @option: value` directives (TypeScript's test-harness
//   equivalent of tsconfig.json) to extract CompilerOpts.  Sections compiled
//   with options ez-checker doesn't yet model are tagged `is_strict` and
//   counted separately — they remain in the denominator (honest) but are
//   broken out in the report.
//
// Cross-file evaluation (fix #3):
//   When a .types file contains multiple sections (19% of the corpus), all
//   compatible sections (ts + dts, or tsx-only, etc.) are concatenated into
//   one source and evaluated with a single checker pass, so types defined in
//   one section are in scope for subsequent sections.

const std = @import("std");
const ez = @import("ez_checker");
const parser = @import("es_parser");
const Checker = ez.Checker;
const ast = parser.ast;
const Ast = ast.Ast;
const NodeIndex = ast.NodeIndex;
const Language = parser.token.Language;

pub const REF_DIR = "typescript/tests/baselines/reference";
const MAX_FILE = 16 * 1024 * 1024;
const MAX_SECTION_SRC = 512 * 1024;
const TOP_N = 16; // rows per breakdown table

// Per-language buckets (informative conformance-by-language table).
const LANG_N = 5;
const LANG_NAMES = [LANG_N][]const u8{ "ts", "d.ts", "tsx", "js", "jsx" };
fn langIdx(l: Language) usize {
    return switch (l) {
        .ts => 0,
        .dts => 1,
        .tsx => 2,
        .js => 3,
        .jsx => 4,
    };
}

// ── Compiler options (parsed from // @ directives in source file) ────────────

const CompilerOpts = struct {
    strict: bool = false,
    strict_null_checks: bool = false,
    no_implicit_any: bool = false,

    // True when any option is set that ez-checker doesn't model yet — sections
    // compiled under these options are still evaluated and counted in the
    // denominator but reported separately.
    fn needsUnimplementedOpts(self: CompilerOpts) bool {
        return self.strict or self.strict_null_checks;
    }
};

// Extract "tests/cases/compiler/foo.ts" from "//// [tests/cases/compiler/foo.ts] ////".
fn extractSourcePath(line: []const u8) ?[]const u8 {
    const pre = "//// [";
    const suf = "] ////";
    if (!std.mem.startsWith(u8, line, pre)) return null;
    if (!std.mem.endsWith(u8, line, suf)) return null;
    return line[pre.len .. line.len - suf.len];
}

// Derive the TypeScript submodule root from ref_dir.
// ref_dir is typically "typescript/tests/baselines/reference".
fn tsRoot(ref_dir: []const u8) ?[]const u8 {
    const suf = "tests/baselines/reference";
    if (!std.mem.endsWith(u8, ref_dir, suf)) return null;
    return std.mem.trimEnd(u8, ref_dir[0 .. ref_dir.len - suf.len], "/");
}

fn parseSourceOpts(io: std.Io, arena: std.mem.Allocator, ts_root_dir: []const u8, source_rel_path: []const u8) CompilerOpts {
    const full_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ ts_root_dir, source_rel_path }) catch return .{};
    const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, arena, std.Io.Limit.limited(64 * 1024)) catch return .{};
    var opts = CompilerOpts{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "// @")) break; // stop at first non-directive
        const rest = line["// @".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const key = std.mem.trim(u8, rest[0..colon], " ");
        const val = std.mem.trim(u8, rest[colon + 1 ..], " ");
        // Stop at filename splits — options after belong to individual files.
        if (std.mem.eql(u8, key, "filename") or std.mem.eql(u8, key, "Filename")) break;
        if (std.mem.eql(u8, key, "strict")) {
            opts.strict = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "strictNullChecks")) {
            opts.strict_null_checks = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "noImplicitAny")) {
            opts.no_implicit_any = std.mem.eql(u8, val, "true");
        }
    }
    return opts;
}

// ════════════════════════════════════════════════════════════════════════════
//  Public surface
// ════════════════════════════════════════════════════════════════════════════

pub const Options = struct {
    ref_dir: []const u8 = REF_DIR,
    filter: ?[]const u8 = null,
    skip: ?[]const u8 = null,
    limit: usize = std.math.maxInt(usize),
    progress: bool = false,
};

pub const Stats = struct {
    files_seen: u64 = 0,
    sections_seen: u64 = 0,
    sections_eval: u64 = 0,
    sections_noncode: u64 = 0,
    sections_large: u64 = 0,
    sections_errored: u64 = 0,
    sections_strict: u64 = 0, // sections compiled with options ez-checker doesn't model

    // ── All-types primary metric (fix #1) ─────────────────────────────────
    // Every baseline expression is bucketed: match + wrong + gap + nonode.
    // nonode = seen - comparable - ambiguous (derived).
    seen: u64 = 0,       // every baseline `>expr : type` entry
    comparable: u64 = 0, // …that resolved to a single ez node
    ambiguous: u64 = 0,  // …excluded: conflicting concrete ez nodes at one anchor
    match: u64 = 0,      // correct (all types)
    wrong: u64 = 0,      // ez returned a different concrete type
    gap: u64 = 0,        // ez returned error/unknown/any for a non-gap tsc type

    // ── Primitive sub-metric (kept for historical comparison) ─────────────
    prim_seen: u64 = 0,
    prim_match: u64 = 0,
    prim_wrong: u64 = 0,
    prim_gap: u64 = 0,
    prim_nonode: u64 = 0,
    prim_ambiguous: u64 = 0, // primitive entries excluded as ambiguous

    prim_seen_lang: [LANG_N]u64 = [_]u64{ 0, 0, 0, 0, 0 },
    prim_match_lang: [LANG_N]u64 = [_]u64{ 0, 0, 0, 0, 0 },
};

pub const Pattern = struct {
    label: []const u8,
    count: u64,
    ex_file: []const u8,
    ex_expr: []const u8,
    ex_want: []const u8,
    ex_got: []const u8,
};

pub const Result = struct {
    stats: Stats,
    wrong: []Pattern,
    gap: []Pattern,
    nonode: []Pattern,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

// ════════════════════════════════════════════════════════════════════════════
//  Sweep
// ════════════════════════════════════════════════════════════════════════════

const Collector = struct {
    ra: std.mem.Allocator,
    wrong: *std.StringHashMap(*Pattern),
    gap: *std.StringHashMap(*Pattern),
    nonode: *std.StringHashMap(*Pattern),

    fn record(self: *Collector, map: *std.StringHashMap(*Pattern), key: []const u8, file: []const u8, expr: []const u8, want: []const u8, got: []const u8) void {
        const gop = map.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const dk = self.ra.dupe(u8, key) catch return;
            gop.key_ptr.* = dk;
            const p = self.ra.create(Pattern) catch return;
            p.* = .{
                .label = dk,
                .count = 0,
                .ex_file = self.ra.dupe(u8, file) catch "",
                .ex_expr = self.ra.dupe(u8, expr) catch "",
                .ex_want = self.ra.dupe(u8, want) catch "",
                .ex_got = self.ra.dupe(u8, got) catch "",
            };
            gop.value_ptr.* = p;
        }
        gop.value_ptr.*.count += 1;
    }
};

pub fn run(opts: Options) !Result {
    const child = std.heap.page_allocator;
    const arena_ptr = try child.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(child);
    errdefer {
        arena_ptr.deinit();
        child.destroy(arena_ptr);
    }
    const ra = arena_ptr.allocator();

    var wrong_map = std.StringHashMap(*Pattern).init(ra);
    var gap_map = std.StringHashMap(*Pattern).init(ra);
    var nonode_map = std.StringHashMap(*Pattern).init(ra);
    var coll = Collector{ .ra = ra, .wrong = &wrong_map, .gap = &gap_map, .nonode = &nonode_map };

    var threaded = std.Io.Threaded.init(child, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, opts.ref_dir, .{ .iterate = true });
    defer dir.close(io);

    // Derive the TypeScript submodule root so we can read source files for
    // compiler option parsing (fix #2).
    const ts_root_dir = tsRoot(opts.ref_dir);

    var stats = Stats{};
    var it = dir.iterate();
    var processed: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".types")) continue;
        if (opts.filter) |f| if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        if (opts.skip) |sl| {
            var skip_it = std.mem.splitScalar(u8, sl, ',');
            var skip = false;
            while (skip_it.next()) |s| {
                if (s.len > 0 and std.mem.indexOf(u8, entry.name, s) != null) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }
        if (processed >= opts.limit) break;
        processed += 1;
        stats.files_seen += 1;

        var file_arena = std.heap.ArenaAllocator.init(child);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const content = dir.readFileAlloc(io, entry.name, fa, std.Io.Limit.limited(MAX_FILE)) catch continue;
        if (opts.progress) std.debug.print("[{d}] {s}\n", .{ processed, entry.name });

        // Parse compiler options from the corresponding source file (fix #2).
        const comp_opts: CompilerOpts = blk: {
            if (ts_root_dir) |root| {
                const first_nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
                const first_line = std.mem.trim(u8, content[0..first_nl], " \r");
                if (extractSourcePath(first_line)) |rel| {
                    break :blk parseSourceOpts(io, fa, root, rel);
                }
            }
            break :blk CompilerOpts{};
        };

        const sections = parseSections(fa, content) catch continue;

        // Evaluate sections — either as a combined program (cross-file fix #3)
        // or independently when languages are incompatible.
        const groups = groupSections(fa, sections) catch {
            // fallback: evaluate independently
            for (sections) |sec| {
                stats.sections_seen += 1;
                const lang = Language.fromExtension(sec.name) orelse {
                    stats.sections_noncode += 1;
                    continue;
                };
                if (sec.source.len > MAX_SECTION_SRC) {
                    stats.sections_large += 1;
                    continue;
                }
                const r = evalSection(fa, sec, lang, comp_opts, &coll);
                accumulateResult(&stats, r, lang, comp_opts);
            }
            continue;
        };

        for (groups) |grp| {
            // Count individual sections (for sections_seen / sections_noncode).
            for (sections[grp.start..grp.end]) |sec| {
                stats.sections_seen += 1;
                if (Language.fromExtension(sec.name) == null) stats.sections_noncode += 1;
            }

            const lang = grp.lang;
            const combined = grp.combined;
            if (combined.source.len > MAX_SECTION_SRC) {
                const count = grp.end - grp.start;
                stats.sections_large += count;
                continue;
            }
            const r = evalSection(fa, combined, lang, comp_opts, &coll);
            // Count sections_eval once per section in the group.
            const section_count = grp.end - grp.start;
            accumulateResultN(&stats, r, lang, comp_opts, section_count);
        }
    }

    return .{
        .stats = stats,
        .wrong = try topPatterns(ra, &wrong_map),
        .gap = try topPatterns(ra, &gap_map),
        .nonode = try topPatterns(ra, &nonode_map),
        .arena = arena_ptr,
    };
}

fn accumulateResult(stats: *Stats, r: SecResult, lang: Language, comp_opts: CompilerOpts) void {
    accumulateResultN(stats, r, lang, comp_opts, 1);
}

fn accumulateResultN(stats: *Stats, r: SecResult, lang: Language, comp_opts: CompilerOpts, n: usize) void {
    switch (r.status) {
        .errored => {
            stats.sections_errored += n;
        },
        .ok => {
            stats.sections_eval += n;
            if (comp_opts.needsUnimplementedOpts()) stats.sections_strict += n;
            stats.seen += r.seen;
            stats.comparable += r.comparable;
            stats.ambiguous += r.ambiguous;
            stats.match += r.match;
            stats.wrong += r.wrong;
            stats.gap += r.gap;
            stats.prim_seen += r.prim_seen;
            stats.prim_match += r.prim_match;
            stats.prim_wrong += r.prim_wrong;
            stats.prim_gap += r.prim_gap;
            stats.prim_nonode += r.prim_nonode;
            stats.prim_ambiguous += r.prim_ambiguous;
            const li = langIdx(lang);
            stats.prim_seen_lang[li] += r.prim_seen;
            stats.prim_match_lang[li] += r.prim_match;
        },
    }
}

// ── Cross-file section grouping (fix #3) ─────────────────────────────────────

const SectionGroup = struct {
    start: usize,  // index into sections slice (inclusive)
    end: usize,    // index into sections slice (exclusive)
    lang: Language,
    combined: Section,
};

// Classify language for grouping: .dts is compatible with .ts (ambient decls).
fn groupLang(lang: Language) u8 {
    return switch (lang) {
        .ts, .dts => 0, // ts+dts go together
        .tsx => 1,
        .js, .jsx => 2,
    };
}

fn combinedLangFor(sections: []const Section, start: usize, end: usize) ?Language {
    var has_ts = false;
    var has_tsx = false;
    var has_js = false;
    for (sections[start..end]) |sec| {
        const lang = Language.fromExtension(sec.name) orelse continue;
        switch (lang) {
            .ts, .dts => has_ts = true,
            .tsx => has_tsx = true,
            .js, .jsx => has_js = true,
        }
    }
    // Return the dominant language for parsing.
    if (has_ts and !has_tsx and !has_js) return .ts;
    if (has_tsx and !has_ts and !has_js) return .tsx;
    if (has_js and !has_ts and !has_tsx) return .js;
    if (has_ts and has_tsx and !has_js) return .tsx; // jsx parser handles ts subset
    return null; // incompatible mix — can't combine
}

// Count newline characters + 1 = number of lines in s.
fn countLines(s: []const u8) u32 {
    var n: u32 = 1;
    for (s) |c| if (c == '\n') { n += 1; };
    return n;
}

fn groupSections(arena: std.mem.Allocator, sections: []const Section) ![]SectionGroup {
    var groups = std.ArrayList(SectionGroup).empty;

    var i: usize = 0;
    while (i < sections.len) {
        // Find a run of sections that share a compatible language group.
        const start = i;
        const first_lang = Language.fromExtension(sections[i].name);
        if (first_lang == null) {
            // Non-code section — skip as a group of one (caller handles noncode).
            i += 1;
            continue;
        }
        const grp_key = groupLang(first_lang.?);
        var end = start + 1;
        while (end < sections.len) : (end += 1) {
            const l = Language.fromExtension(sections[end].name) orelse break;
            if (groupLang(l) != grp_key) break;
        }

        const combined_lang = combinedLangFor(sections, start, end) orelse {
            // Can't combine — emit one group per section.
            for (sections[start..end], start..) |sec, si| {
                const sl = Language.fromExtension(sec.name) orelse {
                    i = si + 1;
                    continue;
                };
                try groups.append(arena, .{
                    .start = si,
                    .end = si + 1,
                    .lang = sl,
                    .combined = sec,
                });
            }
            i = end;
            continue;
        };

        // Concatenate: .dts sections first (ambient declarations), then others.
        var src_parts = std.ArrayList([]const u8).empty;
        var all_entries = std.ArrayList(Entry).empty;
        var line_offset: u32 = 0;

        // Pass 1: dts sections first.
        for (sections[start..end]) |sec| {
            const sl = Language.fromExtension(sec.name) orelse continue;
            if (sl != .dts) continue;
            for (sec.entries) |e| {
                try all_entries.append(arena, .{
                    .line = e.line + line_offset,
                    .expr = e.expr,
                    .type_str = e.type_str,
                });
            }
            try src_parts.append(arena, sec.source);
            line_offset += countLines(sec.source);
        }
        // Pass 2: non-dts sections.
        for (sections[start..end]) |sec| {
            const sl = Language.fromExtension(sec.name) orelse continue;
            if (sl == .dts) continue;
            for (sec.entries) |e| {
                try all_entries.append(arena, .{
                    .line = e.line + line_offset,
                    .expr = e.expr,
                    .type_str = e.type_str,
                });
            }
            try src_parts.append(arena, sec.source);
            line_offset += countLines(sec.source);
        }

        const combined_src = try std.mem.join(arena, "\n", src_parts.items);
        const combined = Section{
            .name = sections[start].name,
            .source = combined_src,
            .entries = try all_entries.toOwnedSlice(arena),
        };
        try groups.append(arena, .{
            .start = start,
            .end = end,
            .lang = combined_lang,
            .combined = combined,
        });
        i = end;
    }
    return groups.toOwnedSlice(arena);
}

fn topPatterns(ra: std.mem.Allocator, map: *std.StringHashMap(*Pattern)) ![]Pattern {
    var list = std.ArrayList(Pattern).empty;
    var it = map.valueIterator();
    while (it.next()) |vp| try list.append(ra, vp.*.*);
    std.mem.sort(Pattern, list.items, {}, struct {
        fn gt(_: void, a: Pattern, b: Pattern) bool {
            return a.count > b.count;
        }
    }.gt);
    return list.toOwnedSlice(ra);
}

pub fn pct(num: u64, den: u64) f64 {
    if (den == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

// ── type categories (for grouping divergences) ──────────────────────────────

fn isNumericLiteralStr(t: []const u8) bool {
    if (t.len == 0) return false;
    var saw_digit = false;
    for (t, 0..) |c, i| {
        if (c >= '0' and c <= '9') saw_digit = true else if (c == '-' and i == 0) {} else if (c == '.') {} else return false;
    }
    return saw_digit;
}

fn typeCategory(t: []const u8) []const u8 {
    const kws = [_][]const u8{
        "string", "number",  "boolean", "void",   "undefined",
        "null",   "never",   "any",     "unknown", "bigint",
        "object", "symbol",  "error",
    };
    for (kws) |k| if (std.mem.eql(u8, t, k)) return k;
    if (t.len == 0) return "(empty)";
    if (t[0] == '"') return "string-literal";
    if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false")) return "boolean-literal";
    if (isNumericLiteralStr(t)) return "number-literal";
    if (std.mem.indexOf(u8, t, " | ") != null) return "union";
    if (std.mem.indexOf(u8, t, "=>") != null or t[0] == '(') return "function";
    if (t[0] == '{') return "object";
    if (std.mem.endsWith(u8, t, "[]")) return "array";
    if (std.mem.indexOfScalar(u8, t, '<') != null) return "generic";
    return "named/other";
}

// ── baseline parsing ───────────────────────────────────────────────────────

const Entry = struct {
    line: u32,
    expr: []const u8,
    type_str: []const u8,
};

const Section = struct {
    name: []const u8,
    source: []u8,
    entries: []Entry,
};

fn isDecoration(body: []const u8) bool {
    var has_caret = false;
    for (body) |c| switch (c) {
        '^' => has_caret = true,
        ' ', '~', ':' => {},
        else => return false,
    };
    return has_caret;
}

fn isSectionHeader(l: []const u8) bool {
    return l.len >= 8 and std.mem.startsWith(u8, l, "=== ") and std.mem.endsWith(u8, l, " ===");
}

fn splitEntry(entry_body: []const u8, deco_body: ?[]const u8) ?struct { expr: []const u8, type_str: []const u8 } {
    if (deco_body) |deco| {
        const caret = std.mem.indexOfScalar(u8, deco, '^') orelse return null;
        if (caret >= entry_body.len) return null;
        const type_str = std.mem.trim(u8, entry_body[caret..], " \r");
        var expr = std.mem.trimEnd(u8, entry_body[0..caret], " \r");
        if (std.mem.endsWith(u8, expr, ":")) expr = std.mem.trimEnd(u8, expr[0 .. expr.len - 1], " \r");
        expr = std.mem.trim(u8, expr, " ");
        if (type_str.len == 0) return null;
        return .{ .expr = expr, .type_str = type_str };
    }
    const idx = std.mem.lastIndexOf(u8, entry_body, " : ") orelse return null;
    const expr = std.mem.trim(u8, entry_body[0..idx], " ");
    const type_str = std.mem.trim(u8, entry_body[idx + 3 ..], " \r");
    if (type_str.len == 0) return null;
    return .{ .expr = expr, .type_str = type_str };
}

fn collectSection(arena: std.mem.Allocator, name: []const u8, body: []const []const u8) !Section {
    var src_lines = std.ArrayList([]const u8).empty;
    var entries = std.ArrayList(Entry).empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const line = body[i];
        if (line.len > 0 and line[0] == '>') {
            const entry_body = line[1..];
            if (isDecoration(entry_body)) continue;
            if (std.mem.indexOf(u8, entry_body, " : ") == null and
                std.mem.indexOf(u8, entry_body, " :") == null) continue;
            if (src_lines.items.len == 0) continue;
            const src_line: u32 = @intCast(src_lines.items.len - 1);
            const deco: ?[]const u8 = blk: {
                if (i + 1 < body.len and body[i + 1].len > 0 and body[i + 1][0] == '>') {
                    const nb = body[i + 1][1..];
                    if (isDecoration(nb)) break :blk nb;
                }
                break :blk null;
            };
            if (splitEntry(entry_body, deco)) |se| {
                try entries.append(arena, .{ .line = src_line, .expr = se.expr, .type_str = se.type_str });
            }
        } else {
            try src_lines.append(arena, line);
        }
    }
    return .{
        .name = name,
        .source = try std.mem.join(arena, "\n", src_lines.items),
        .entries = try entries.toOwnedSlice(arena),
    };
}

fn parseSections(arena: std.mem.Allocator, content: []const u8) ![]Section {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| try lines.append(arena, std.mem.trimEnd(u8, l, "\r"));
    if (lines.items.len < 3) return &.{};
    if (!std.mem.startsWith(u8, lines.items[0], "//// [")) return &.{};

    var sections = std.ArrayList(Section).empty;
    var i: usize = 1;
    while (i < lines.items.len) {
        if (!isSectionHeader(lines.items[i])) {
            i += 1;
            continue;
        }
        const name = lines.items[i][4 .. lines.items[i].len - 4];
        i += 1;
        const start = i;
        while (i < lines.items.len and !isSectionHeader(lines.items[i])) : (i += 1) {}
        try sections.append(arena, try collectSection(arena, name, lines.items[start..i]));
    }
    return sections.toOwnedSlice(arena);
}

// ── type-string normalization ──────────────────────────────────────────────

fn isPrimitiveType(s: []const u8) bool {
    var it = std.mem.splitSequence(u8, s, " | ");
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (!isPrimitiveAtom(p)) return false;
    }
    return true;
}

fn isPrimitiveAtom(p: []const u8) bool {
    const kws = [_][]const u8{
        "string", "number",  "boolean", "void",   "undefined",
        "null",   "never",   "any",     "unknown", "bigint",
        "object", "symbol",  "true",    "false",
    };
    for (kws) |k| if (std.mem.eql(u8, p, k)) return true;
    if (p.len == 0) return false;
    if (p[0] == '"' and p[p.len - 1] == '"') return true;
    return isNumericLiteralStr(p);
}

// Sort the members of a simple union or intersection (fix #5).
// Skips sorting if the type contains structural characters that would make
// naive splitting ambiguous (e.g. `{ x: A | B }` must not be split on " | ").
fn sortMembers(arena: std.mem.Allocator, s: []const u8, sep: []const u8) !?[]const u8 {
    for (s) |c| switch (c) {
        '{', '}', '(', ')', '<', '>', '[', ']', '=' => return null,
        else => {},
    };
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |p| try parts.append(arena, std.mem.trim(u8, p, " "));
    if (parts.items.len <= 1) return null; // nothing to sort
    std.mem.sort([]const u8, parts.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return try std.mem.join(arena, sep, parts.items);
}

fn normalizeType(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \r");

    // Sort union members for order-independent comparison.
    if (std.mem.indexOf(u8, trimmed, " | ") != null) {
        if (try sortMembers(arena, trimmed, " | ")) |sorted| return sorted;
    }
    // Sort intersection members similarly.
    if (std.mem.indexOf(u8, trimmed, " & ") != null) {
        if (try sortMembers(arena, trimmed, " & ")) |sorted| return sorted;
    }
    return trimmed;
}

// ── exact node source span ──────────────────────────────────────────────────

fn leftmostStart(a: *const Ast, node: NodeIndex) u32 {
    if (node == .none) return std.math.maxInt(u32);
    const own = a.tokenStart(a.nodeMainToken(node));
    const recurse = switch (a.nodeTag(node)) {
        .add, .subtract, .multiply, .divide, .modulo, .exponentiate,
        .equal, .not_equal, .strict_equal, .strict_not_equal,
        .less_than, .greater_than, .less_equal, .greater_equal,
        .instanceof_expr, .in_expr,
        .bitwise_and, .bitwise_or, .bitwise_xor,
        .shift_left, .shift_right, .unsigned_shift_right,
        .logical_and, .logical_or, .nullish_coalesce,
        .assign, .add_assign, .sub_assign, .mul_assign, .div_assign,
        .mod_assign, .exp_assign, .and_assign, .or_assign, .xor_assign,
        .shl_assign, .shr_assign, .ushr_assign,
        .logical_and_assign, .logical_or_assign, .nullish_assign,
        .call_expr, .optional_call_expr, .new_expr,
        .member_expr, .computed_member_expr,
        .optional_member_expr, .optional_computed_member_expr,
        .conditional, .sequence_expr, .tagged_template,
        .postfix_inc, .postfix_dec,
        .ts_non_null_expr, .ts_as_expr, .ts_satisfies_expr,
        .ts_instantiation_expr,
        => true,
        else => false,
    };
    var start = own;
    if (recurse) {
        const child = a.nodeData(node).lhs;
        if (child != .none and child.toInt() < node.toInt()) {
            const cs = leftmostStart(a, child);
            if (cs < start) start = cs;
        }
    }
    return start;
}

const Span = struct { start: u32, end: u32 };

fn nodeSpanFull(a: *const Ast, node: NodeIndex) Span {
    const start = leftmostStart(a, node);
    const i = node.toInt();
    var end: u32 = a.nodeSpan(node).end;
    if (i < a.node_end_toks.len) {
        const et = a.node_end_toks[i];
        end = a.tokenStart(et) + a.tokens.items(.len)[et];
    }
    return .{ .start = @min(start, end), .end = end };
}

// ── per-section evaluation ────────────────────────────────────────────────────

const Status = enum { ok, errored };

const SecResult = struct {
    status: Status = .ok,
    // All-types (primary metric)
    seen: u32 = 0,
    comparable: u32 = 0,
    ambiguous: u32 = 0,
    match: u32 = 0,
    wrong: u32 = 0,
    gap: u32 = 0,
    // Primitive sub-metric
    prim_seen: u32 = 0,
    prim_match: u32 = 0,
    prim_wrong: u32 = 0,
    prim_gap: u32 = 0,
    prim_nonode: u32 = 0,
    prim_ambiguous: u32 = 0,
};

fn isGapType(s: []const u8) bool {
    return std.mem.eql(u8, s, "error") or
        std.mem.eql(u8, s, "unknown") or
        std.mem.eql(u8, s, "any");
}

const AMBIG = "\x00AMBIG";

fn lineStarts(arena: std.mem.Allocator, src: []const u8) ![]u32 {
    var starts = std.ArrayList(u32).empty;
    try starts.append(arena, 0);
    for (src, 0..) |c, idx| {
        if (c == '\n') try starts.append(arena, @intCast(idx + 1));
    }
    return starts.toOwnedSlice(arena);
}

fn lineOf(starts: []const u32, offset: u32) u32 {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo - 1);
}

fn evalSection(arena: std.mem.Allocator, sec: Section, lang: Language, opts: CompilerOpts, coll: *Collector) SecResult {
    _ = opts; // reserved for future checker option passing
    return evalSectionInner(arena, sec, lang, coll) catch SecResult{ .status = .errored };
}

fn evalSectionInner(arena: std.mem.Allocator, sec: Section, lang: Language, coll: *Collector) !SecResult {
    var res = SecResult{ .status = .ok };
    if (sec.entries.len == 0) return res;
    const source = sec.source;

    var lex = try parser.Lexer.tokenizeWithLanguage(arena, source, lang);
    var ast_result = try parser.Parser.parseWithLanguage(arena, source, lex.tokens.slice(), lang, true);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(
        arena,
        &ast_result,
        .{ .is_module = true, .build_parents = true },
    );
    var checker = try Checker.init(arena, &ast_result, &sem);

    const starts = try lineStarts(arena, source);

    const Key = struct { line: u32, text: []const u8 };
    const Ctx = struct {
        pub fn hash(_: @This(), k: Key) u64 {
            var h = std.hash.Wyhash.init(k.line);
            h.update(k.text);
            return h.final();
        }
        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a.line == b.line and std.mem.eql(u8, a.text, b.text);
        }
    };
    var map = std.HashMap(Key, []const u8, Ctx, 80).init(arena);

    const total_nodes: u32 = @intCast(ast_result.nodes.len);
    var n: u32 = 0;
    while (n < total_nodes) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const span = nodeSpanFull(&ast_result, ni);
        if (span.end <= span.start or span.end > source.len) continue;
        const text = source[span.start..span.end];
        if (text.len == 0) continue;
        if (std.mem.indexOfScalar(u8, text, '\n') != null) continue;
        const line = lineOf(starts, span.start);
        const ty = checker.typeOf(ni);
        const tystr = checker.typeToString(ty) catch continue;
        const key = Key{ .line = line, .text = text };
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = tystr;
            continue;
        }
        const old = gop.value_ptr.*;
        if (std.mem.eql(u8, old, tystr) or std.mem.eql(u8, old, AMBIG)) continue;
        const old_gap = isGapType(old);
        const new_gap = isGapType(tystr);
        if (old_gap and !new_gap) {
            gop.value_ptr.* = tystr;
        } else if (!old_gap and !new_gap) {
            gop.value_ptr.* = AMBIG;
        }
    }

    var keybuf: [128]u8 = undefined;
    for (sec.entries) |e| {
        res.seen += 1;
        const want = try normalizeType(arena, e.type_str);
        const is_prim = isPrimitiveType(want);
        if (is_prim) res.prim_seen += 1;

        const got_raw = map.get(Key{ .line = e.line, .text = e.expr });
        const is_ambig = got_raw != null and std.mem.eql(u8, got_raw.?, AMBIG);
        if (got_raw == null or is_ambig) {
            // fix #4: track ambiguous anchors separately from no-node.
            if (is_ambig) {
                res.ambiguous += 1;
                if (is_prim) res.prim_ambiguous += 1;
            }
            if (is_prim and !is_ambig) {
                res.prim_nonode += 1;
                coll.record(coll.nonode, typeCategory(want), sec.name, e.expr, want, "<no node>");
            } else if (is_prim and is_ambig) {
                coll.record(coll.nonode, typeCategory(want), sec.name, e.expr, want, "<ambiguous>");
            }
            continue;
        }
        res.comparable += 1;
        const got_norm = try normalizeType(arena, got_raw.?);
        if (std.mem.eql(u8, got_norm, want)) {
            // Correct.
            res.match += 1;
            if (is_prim) res.prim_match += 1;
        } else if (isGapType(got_norm)) {
            // ez returned a gap type where tsc has a concrete type.
            res.gap += 1;
            if (is_prim) res.prim_gap += 1;
            coll.record(coll.gap, typeCategory(want), sec.name, e.expr, want, got_norm);
        } else {
            // ez returned a different concrete type — a real divergence.
            res.wrong += 1;
            if (is_prim) res.prim_wrong += 1;
            const label = std.fmt.bufPrint(&keybuf, "{s} → {s}", .{ typeCategory(want), typeCategory(got_norm) }) catch typeCategory(want);
            coll.record(coll.wrong, label, sec.name, e.expr, want, got_norm);
        }
    }
    return res;
}

// ════════════════════════════════════════════════════════════════════════════
//  Reporting
// ════════════════════════════════════════════════════════════════════════════

fn printPatterns(title: []const u8, pats: []const Pattern, total: u64) void {
    std.debug.print("\n {s}\n", .{title});
    if (pats.len == 0) {
        std.debug.print("   (none)\n", .{});
        return;
    }
    var shown: usize = 0;
    for (pats) |p| {
        if (shown >= TOP_N) break;
        shown += 1;
        std.debug.print("   {d:>7} {d:>4.1}%  {s}\n", .{ p.count, pct(p.count, total), p.label });
        std.debug.print("            e.g. {s}:  `{s}`  want `{s}`  got `{s}`\n", .{ p.ex_file, ellipsis(p.ex_expr, 48), ellipsis(p.ex_want, 40), ellipsis(p.ex_got, 40) });
    }
    if (pats.len > shown) std.debug.print("   … {d} more categories\n", .{pats.len - shown});
}

fn ellipsis(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

pub fn printReport(res: Result) void {
    const s = res.stats;
    const all_nonode = s.seen - s.comparable - s.ambiguous;
    const all_denom = s.seen; // honest: includes no-node and ambiguous in denominator
    std.debug.print("\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print(" ez-checker × TypeScript corpus oracle\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print(" files                : {d}\n", .{s.files_seen});
    std.debug.print(" sections             : {d} total\n", .{s.sections_seen});
    std.debug.print("   ├─ evaluated       : {d}\n", .{s.sections_eval});
    std.debug.print("   ├─ strict opts     : {d}  (options ez-checker doesn't model yet)\n", .{s.sections_strict});
    std.debug.print("   ├─ non-code skip   : {d}  (.json / no extension)\n", .{s.sections_noncode});
    std.debug.print("   ├─ too-large skip  : {d}  (reconstructed source > 512 KiB)\n", .{s.sections_large});
    std.debug.print("   └─ pipeline errors : {d}\n", .{s.sections_errored});
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    std.debug.print(" ALL-TYPES conformance (primary metric)\n", .{});
    std.debug.print("   baseline expressions : {d}\n", .{s.seen});
    std.debug.print("   ├─ correct          : {d:>7}  ({d:.1}%)  ← conformance\n", .{ s.match, pct(s.match, all_denom) });
    std.debug.print("   ├─ wrong concrete   : {d:>7}  (ez disagrees — divergence / bug)\n", .{s.wrong});
    std.debug.print("   ├─ coverage gap     : {d:>7}  (ez = error/unknown/any — unmodeled)\n", .{s.gap});
    std.debug.print("   ├─ no ez node       : {d:>7}  (no comparable node — anchoring gap)\n", .{all_nonode});
    std.debug.print("   └─ ambiguous anchor : {d:>7}  (conflicting ez nodes — excluded)\n", .{s.ambiguous});
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    std.debug.print(" PRIMITIVE sub-metric  (string/number/boolean/literal/union-of-above)\n", .{});
    std.debug.print("   ├─ correct         : {d:>7}/{d:<7}  ({d:.1}%)\n", .{ s.prim_match, s.prim_seen, pct(s.prim_match, s.prim_seen) });
    std.debug.print("   ├─ wrong concrete  : {d:>7}\n", .{s.prim_wrong});
    std.debug.print("   ├─ coverage gap    : {d:>7}\n", .{s.prim_gap});
    std.debug.print("   ├─ no ez node      : {d:>7}\n", .{s.prim_nonode});
    std.debug.print("   └─ ambiguous       : {d:>7}\n", .{s.prim_ambiguous});

    // Per-language conformance (primitive sub-metric).
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    std.debug.print(" primitive conformance by language:\n", .{});
    for (0..LANG_N) |li| {
        const seen = s.prim_seen_lang[li];
        if (seen == 0) continue;
        std.debug.print("   {s:<6}: {d:>7}/{d:<7}  ({d:.1}%)\n", .{ LANG_NAMES[li], s.prim_match_lang[li], seen, pct(s.prim_match_lang[li], seen) });
    }

    // Failure breakdowns — cover ALL types now (fix #1).
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    printPatterns("wrong concrete — tsc category → ez category:", res.wrong, s.wrong);
    printPatterns("coverage gap — tsc category ez returns error/unknown/any for:", res.gap, s.gap);
    printPatterns("no ez node — tsc category with no comparable ez node:", res.nonode, all_nonode);
    std.debug.print("══════════════════════════════════════════════════════════════\n", .{});
}

// ════════════════════════════════════════════════════════════════════════════
//  Executable entry point — `zig build run-oracle`
// ════════════════════════════════════════════════════════════════════════════

fn getEnv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
            if (std.mem.eql(u8, s[0..eq], name)) return s[eq + 1 ..];
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var save_baseline = false;
    for (init.minimal.args.vector) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "--save-baseline")) save_baseline = true;
    }

    const opts = Options{
        .ref_dir = getEnv("ORACLE_DIR") orelse REF_DIR,
        .filter = getEnv("ORACLE_FILTER"),
        .skip = getEnv("ORACLE_SKIP"),
        .limit = blk: {
            if (getEnv("ORACLE_LIMIT")) |lv| {
                break :blk std.fmt.parseInt(usize, lv, 10) catch std.math.maxInt(usize);
            }
            break :blk std.math.maxInt(usize);
        },
        .progress = getEnv("ORACLE_PROGRESS") != null,
    };

    var res = run(opts) catch |err| {
        std.debug.print("error: corpus sweep failed: {s}\n", .{@errorName(err)});
        std.debug.print("(run from the ez-checker repo root so the typescript/ submodule is reachable)\n", .{});
        return err;
    };
    defer res.deinit();
    printReport(res);

    if (save_baseline) try writeBaseline(init.io, init.gpa, res.stats);
}

fn writeBaseline(io: std.Io, gpa: std.mem.Allocator, s: Stats) !void {
    const all_nonode = s.seen - s.comparable - s.ambiguous;
    const content = try std.fmt.allocPrint(gpa,
        \\# ez-checker × TypeScript corpus conformance ratchet.
        \\#
        \\# Generated by `zig build save-baseline` — DO NOT hand-edit. Enforced by
        \\# `zig build test-oracle`; the test FAILS if conformance regresses:
        \\#   * match drops below match_min            (fewer correct answers — all types)
        \\#   * wrong rises above wrong_max            (more wrong concrete answers — all types)
        \\#   * prim_match drops below prim_match_min  (primitive sub-metric floor)
        \\#   * sections_eval drops below sections_eval_min
        \\#   * any section raises a pipeline error
        \\#
        \\# Full corpus snapshot:
        \\#   all-types correct = {d}/{d} ({d:.1}%)   wrong = {d}   gap = {d}   no-node = {d}   ambig = {d}
        \\#   primitive correct = {d}/{d} ({d:.1}%)   wrong = {d}   gap = {d}   no-node = {d}
        \\sections_eval_min {d}
        \\match_min {d}
        \\wrong_max {d}
        \\prim_match_min {d}
        \\prim_wrong_max {d}
        \\
    , .{
        s.match,      s.seen,      pct(s.match, s.seen),
        s.wrong,      s.gap,       all_nonode, s.ambiguous,
        s.prim_match, s.prim_seen, pct(s.prim_match, s.prim_seen),
        s.prim_wrong, s.prim_gap,  s.prim_nonode,
        s.sections_eval, s.match, s.wrong, s.prim_match, s.prim_wrong,
    });
    defer gpa.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "oracle/baseline.lock", .data = content });
    std.debug.print("\nwrote oracle/baseline.lock  (match_min={d} wrong_max={d} prim_match_min={d})\n", .{ s.match, s.wrong, s.prim_match });
}

// ════════════════════════════════════════════════════════════════════════════
//  Test suite — `zig build test-oracle`
// ════════════════════════════════════════════════════════════════════════════

const baseline_lock = @embedFile("oracle/baseline.lock");

fn lockValue(key: []const u8) !u64 {
    var it = std.mem.splitScalar(u8, baseline_lock, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..sp], " "), key)) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, line[sp + 1 ..], " "), 10);
        }
    }
    return error.LockKeyMissing;
}

test "oracle: TypeScript corpus conformance (ratchet)" {
    var res = run(.{}) catch |err| {
        std.debug.print("corpus sweep failed ({s}); is the typescript/ submodule checked out " ++
            "and are you running `zig build test-oracle` from the repo root?\n", .{@errorName(err)});
        return err;
    };
    defer res.deinit();
    printReport(res);
    const s = res.stats;

    const sections_eval_min = try lockValue("sections_eval_min");
    const match_min         = try lockValue("match_min");
    const wrong_max         = try lockValue("wrong_max");
    const prim_match_min    = try lockValue("prim_match_min");
    const prim_wrong_max    = try lockValue("prim_wrong_max");

    var failed = false;
    if (s.sections_errored != 0) {
        std.debug.print("REGRESSION: {d} section(s) raised pipeline errors (expected 0)\n", .{s.sections_errored});
        failed = true;
    }
    if (s.sections_eval < sections_eval_min) {
        std.debug.print("REGRESSION: sections_eval {d} < baseline {d}\n", .{ s.sections_eval, sections_eval_min });
        failed = true;
    }
    if (s.match < match_min) {
        std.debug.print("REGRESSION: match {d} < baseline {d} (fewer correct answers)\n", .{ s.match, match_min });
        failed = true;
    }
    if (s.wrong > wrong_max) {
        std.debug.print("REGRESSION: wrong {d} > baseline {d} (more wrong answers)\n", .{ s.wrong, wrong_max });
        failed = true;
    }
    if (s.prim_match < prim_match_min) {
        std.debug.print("REGRESSION: prim_match {d} < baseline {d}\n", .{ s.prim_match, prim_match_min });
        failed = true;
    }
    if (s.prim_wrong > prim_wrong_max) {
        std.debug.print("REGRESSION: prim_wrong {d} > baseline {d}\n", .{ s.prim_wrong, prim_wrong_max });
        failed = true;
    }
    if (failed) return error.ConformanceRegressed;

    if (s.match > match_min or s.wrong < wrong_max or s.sections_eval > sections_eval_min) {
        std.debug.print(
            "IMPROVED — bump oracle/baseline.lock: match_min={d} wrong_max={d} prim_match_min={d}\n",
            .{ s.match, s.wrong, s.prim_match },
        );
    }
}
