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
// verbose by default. Multi-section baselines are evaluated section-by-section
// (each in its own language). Every primitive-typed baseline expression lands in
// exactly one reported bucket — correct / wrong / coverage-gap / no-node — so the
// denominator can't be shrunk to flatter the rate. The report then breaks the
// failures down by *systematic pattern* (which kinds of types ez gets wrong /
// can't model) with a concrete example each, and by source language — so you can
// see at a glance WHERE ez diverges, not just how often.
//
// Anchoring strategy (why this is robust):
//   A `.types` section interleaves each source line with `>expr : type` entries
//   for the expressions starting on that line. We collect the non-`>` lines as
//   the "effective source" — *exactly* the text the baseline's expr fragments
//   were sliced from — so parsing it lines AST node line-numbers and node
//   source-text up with the baseline with zero realignment. Each entry's type
//   boundary is the decoration line's first `^` column (the only reliable
//   expr/type split, since both exprs and types can contain " : ").

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

// ════════════════════════════════════════════════════════════════════════════
//  Public surface
// ════════════════════════════════════════════════════════════════════════════

pub const Options = struct {
    ref_dir: []const u8 = REF_DIR,
    filter: ?[]const u8 = null, // only files whose name contains this
    skip: ?[]const u8 = null, // skip files whose name contains any (comma-sep)
    limit: usize = std.math.maxInt(usize), // stop after N files
    progress: bool = false, // print each file as processed (locating hangs)
};

pub const Stats = struct {
    files_seen: u64 = 0,
    sections_seen: u64 = 0,
    sections_eval: u64 = 0,
    sections_noncode: u64 = 0, // .json / no extension
    sections_large: u64 = 0, // reconstructed source over the cap
    sections_errored: u64 = 0,

    seen: u64 = 0, // every baseline `>expr : type` entry
    comparable: u64 = 0, // …that resolved to a single ez node
    match: u64 = 0, // …and ez agreed with tsc (all types)
    ambiguous: u64 = 0, // dropped: conflicting ez nodes at one anchor

    prim_seen: u64 = 0, // primitive/literal subset (= match+wrong+gap+nonode)
    prim_match: u64 = 0,
    prim_wrong: u64 = 0,
    prim_gap: u64 = 0,
    prim_nonode: u64 = 0,

    prim_seen_lang: [LANG_N]u64 = [_]u64{ 0, 0, 0, 0, 0 },
    prim_match_lang: [LANG_N]u64 = [_]u64{ 0, 0, 0, 0, 0 },
};

/// One row of a failure breakdown: a category pattern, a count, and a concrete
/// example so the divergence is actionable, not just a number.
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
    wrong: []Pattern, // wrong-concrete, grouped by `wantCategory → gotCategory`
    gap: []Pattern, // coverage-gap, grouped by want category
    nonode: []Pattern, // no-ez-node, grouped by want category
    arena: *std.heap.ArenaAllocator, // owns the slices above

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

/// Sweep the corpus and return aggregate stats + failure breakdowns. Per-section
/// pipeline errors are counted, not propagated, so one bad section can't abort
/// the sweep. Caller owns the Result and must `deinit()` it.
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

        const sections = parseSections(fa, content) catch continue;
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
            const r = evalSection(fa, sec, lang, &coll);
            switch (r.status) {
                .errored => {
                    stats.sections_errored += 1;
                    std.debug.print("  [{s} / {s}] pipeline error\n", .{ entry.name, sec.name });
                },
                .ok => {
                    stats.sections_eval += 1;
                    stats.seen += r.seen;
                    stats.comparable += r.comparable;
                    stats.match += r.match;
                    stats.ambiguous += r.ambiguous;
                    stats.prim_seen += r.prim_seen;
                    stats.prim_match += r.prim_match;
                    stats.prim_wrong += r.prim_wrong;
                    stats.prim_gap += r.prim_gap;
                    stats.prim_nonode += r.prim_nonode;
                    const li = langIdx(lang);
                    stats.prim_seen_lang[li] += r.prim_seen;
                    stats.prim_match_lang[li] += r.prim_match;
                },
            }
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

/// Collapse a concrete type string to a small, bounded category so failure
/// breakdowns are meaningful (literals/objects don't explode into thousands of
/// one-off rows).
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

fn normalizeType(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \r");
    if (std.mem.indexOf(u8, trimmed, " | ") == null) return trimmed;
    for (trimmed) |c| switch (c) {
        '{', '}', '(', ')', '<', '>', '[', ']', '=' => return trimmed,
        else => {},
    };
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitSequence(u8, trimmed, " | ");
    while (it.next()) |p| try parts.append(arena, std.mem.trim(u8, p, " "));
    std.mem.sort([]const u8, parts.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return std.mem.join(arena, " | ", parts.items);
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
    seen: u32 = 0,
    comparable: u32 = 0,
    match: u32 = 0,
    ambiguous: u32 = 0,
    prim_seen: u32 = 0,
    prim_match: u32 = 0,
    prim_wrong: u32 = 0,
    prim_gap: u32 = 0,
    prim_nonode: u32 = 0,
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

fn evalSection(arena: std.mem.Allocator, sec: Section, lang: Language, coll: *Collector) SecResult {
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
        // Same (line, text) anchor, different ez types. tsc's entry is for one
        // expression; an enclosing/structural node often shares the text but
        // only knows `unknown`/`error`/`any`. Prefer the concrete answer; only
        // call it ambiguous when two *different concrete* types genuinely
        // conflict (e.g. a value narrowed differently twice on one line).
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

        const got = map.get(Key{ .line = e.line, .text = e.expr });
        if (got == null or std.mem.eql(u8, got.?, AMBIG)) {
            if (got != null) res.ambiguous += 1;
            if (is_prim) {
                res.prim_nonode += 1;
                coll.record(coll.nonode, typeCategory(want), sec.name, e.expr, want, if (got != null) "<ambiguous>" else "<no node>");
            }
            continue;
        }
        res.comparable += 1;
        const got_norm = try normalizeType(arena, got.?);
        if (std.mem.eql(u8, got_norm, want)) {
            res.match += 1;
            if (is_prim) res.prim_match += 1;
        } else if (is_prim) {
            if (isGapType(got_norm)) {
                res.prim_gap += 1;
                coll.record(coll.gap, typeCategory(want), sec.name, e.expr, want, got_norm);
            } else {
                res.prim_wrong += 1;
                const label = std.fmt.bufPrint(&keybuf, "{s} → {s}", .{ typeCategory(want), typeCategory(got_norm) }) catch typeCategory(want);
                coll.record(coll.wrong, label, sec.name, e.expr, want, got_norm);
            }
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
    const nonode_all = s.seen - s.comparable;
    std.debug.print("\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print(" ez-checker × TypeScript corpus oracle\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print(" files                : {d}\n", .{s.files_seen});
    std.debug.print(" sections             : {d} total\n", .{s.sections_seen});
    std.debug.print("   ├─ evaluated       : {d}\n", .{s.sections_eval});
    std.debug.print("   ├─ non-code skip   : {d}  (.json / no extension)\n", .{s.sections_noncode});
    std.debug.print("   ├─ too-large skip  : {d}  (reconstructed source > 512 KiB)\n", .{s.sections_large});
    std.debug.print("   └─ pipeline errors : {d}\n", .{s.sections_errored});
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    std.debug.print(" baseline expressions : {d}\n", .{s.seen});
    std.debug.print("   comparable (ez node): {d}   ({d} had no comparable node; {d} ambiguous)\n", .{ s.comparable, nonode_all, s.ambiguous });
    std.debug.print(" all-types match      : {d}/{d}  ({d:.1}% of comparable)\n", .{ s.match, s.comparable, pct(s.match, s.comparable) });
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    std.debug.print(" primitive subset     : {d} expressions (every one bucketed)\n", .{s.prim_seen});
    std.debug.print("   ├─ correct         : {d:>7}  ({d:.1}%)  ← conformance\n", .{ s.prim_match, pct(s.prim_match, s.prim_seen) });
    std.debug.print("   ├─ wrong concrete  : {d:>7}  (ez disagrees — divergence / bug)\n", .{s.prim_wrong});
    std.debug.print("   ├─ coverage gap    : {d:>7}  (ez = error/unknown/any — unmodeled)\n", .{s.prim_gap});
    std.debug.print("   └─ no ez node      : {d:>7}  (no comparable node — anchoring / coverage gap)\n", .{s.prim_nonode});

    // Per-language conformance.
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    std.debug.print(" conformance by language (primitive correct / seen):\n", .{});
    for (0..LANG_N) |li| {
        const seen = s.prim_seen_lang[li];
        if (seen == 0) continue;
        std.debug.print("   {s:<6}: {d:>7}/{d:<7}  ({d:.1}%)\n", .{ LANG_NAMES[li], s.prim_match_lang[li], seen, pct(s.prim_match_lang[li], seen) });
    }

    // Failure breakdowns — the "verbose by default" detail: WHERE ez diverges.
    std.debug.print("──────────────────────────────────────────────────────────────\n", .{});
    printPatterns("wrong concrete — tsc category → ez category:", res.wrong, s.prim_wrong);
    printPatterns("coverage gap — tsc category ez returns error/unknown/any for:", res.gap, s.prim_gap);
    printPatterns("no ez node — tsc category with no comparable ez node:", res.nonode, s.prim_nonode);
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

/// Overwrite oracle/baseline.lock with the current run's numbers. The ratchet
/// baseline is tool-generated, never hand-edited — run `zig build save-baseline`
/// (or `oracle --save-baseline`) to accept the current conformance as the new
/// floor after a verified improvement.
fn writeBaseline(io: std.Io, gpa: std.mem.Allocator, s: Stats) !void {
    const content = try std.fmt.allocPrint(gpa,
        \\# ez-checker × TypeScript corpus conformance ratchet.
        \\#
        \\# Generated by `zig build save-baseline` — DO NOT hand-edit. Enforced by
        \\# `zig build test-oracle`; the test FAILS if conformance regresses:
        \\#   * prim_match drops below prim_match_min        (fewer correct answers)
        \\#   * prim_wrong rises above prim_wrong_max         (more wrong concrete answers)
        \\#   * sections_eval drops below sections_eval_min   (sections stopped evaluating)
        \\#   * any section raises a pipeline error           (sections_errored must be 0)
        \\#
        \\# Full corpus snapshot (every primitive expression bucketed):
        \\#   primitive correct = {d}/{d} ({d:.1}%)   wrong = {d}   gap = {d}   no-node = {d}
        \\#   all-types match   = {d}/{d} ({d:.1}% of comparable)
        \\sections_eval_min {d}
        \\prim_match_min {d}
        \\prim_wrong_max {d}
        \\
    , .{
        s.prim_match,   s.prim_seen,  pct(s.prim_match, s.prim_seen),
        s.prim_wrong,   s.prim_gap,   s.prim_nonode,
        s.match,        s.comparable, pct(s.match, s.comparable),
        s.sections_eval, s.prim_match, s.prim_wrong,
    });
    defer gpa.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "oracle/baseline.lock", .data = content });
    std.debug.print("\nwrote oracle/baseline.lock  (sections_eval_min={d} prim_match_min={d} prim_wrong_max={d})\n", .{ s.sections_eval, s.prim_match, s.prim_wrong });
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
    printReport(res); // verbose by default — the full breakdown prints every run
    const s = res.stats;

    const sections_eval_min = try lockValue("sections_eval_min");
    const prim_match_min = try lockValue("prim_match_min");
    const prim_wrong_max = try lockValue("prim_wrong_max");

    var failed = false;
    if (s.sections_errored != 0) {
        std.debug.print("REGRESSION: {d} section(s) raised pipeline errors (expected 0)\n", .{s.sections_errored});
        failed = true;
    }
    if (s.sections_eval < sections_eval_min) {
        std.debug.print("REGRESSION: sections_eval {d} < baseline {d} (sections stopped evaluating)\n", .{ s.sections_eval, sections_eval_min });
        failed = true;
    }
    if (s.prim_match < prim_match_min) {
        std.debug.print("REGRESSION: prim_match {d} < baseline {d} (fewer correct answers)\n", .{ s.prim_match, prim_match_min });
        failed = true;
    }
    if (s.prim_wrong > prim_wrong_max) {
        std.debug.print("REGRESSION: prim_wrong {d} > baseline {d} (more wrong answers)\n", .{ s.prim_wrong, prim_wrong_max });
        failed = true;
    }
    if (failed) return error.ConformanceRegressed;

    if (s.prim_match > prim_match_min or s.prim_wrong < prim_wrong_max or s.sections_eval > sections_eval_min) {
        std.debug.print(
            "IMPROVED — bump oracle/baseline.lock: sections_eval_min={d} prim_match_min={d} prim_wrong_max={d}\n",
            .{ s.sections_eval, s.prim_match, s.prim_wrong },
        );
    }
}
