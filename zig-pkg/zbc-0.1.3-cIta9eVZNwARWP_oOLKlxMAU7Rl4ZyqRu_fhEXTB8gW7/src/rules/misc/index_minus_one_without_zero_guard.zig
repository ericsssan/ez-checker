//! Detects array subscript expressions of the form `buf[idx - 1]` where the
//! `idx - 1` subtraction is not guarded against `idx == 0`.  When `idx` is
//! `usize` and equals zero, `idx - 1` wraps to `maxInt(usize)` —
//! an OOB trap in Debug/Safe and a silent arbitrary-memory read in
//! ReleaseFast.
//!
//! Real-world instances:
//!   - oven-sh/bun#24561 (hosted_git_info.zig): `npa_str[pi - 1]` where `pi`
//!     optional payload could be 0; fix added `pi == 0 or` guard.
//!   - oven-sh/bun#28487 (braces.zig): `self.items[self.current - 1]` when
//!     `self.current` could be 0; fix added `if (self.current > 0)` guard.
//!   - ziglang/zig#26057 (ArgIteratorWasi): `self.args[self.args.len - 1]`
//!     panics when `self.args.len == 0`; `0 - 1` wraps to `maxInt(usize)`.
//!
//! Detection (Tier 1, token walk):
//!   Form A: `[ identifier - 1 ]`                          (5 tokens)
//!   Form B: `[ identifier . identifier - 1 ]`             (7 tokens)
//!   Form C: `[ identifier . identifier . len - 1 ]`       (9 tokens)
//!   Fire at the `l_bracket` token.
//!
//! Suppression (six checks, all applied):
//!
//!   1. Same-expression `and`-guard (window 15): `GUARD_IDENT (> N | >= N | !=) 0
//!      keyword_and` immediately before the array identifier.
//!      Covers `x > 0`, `x >= 1`, `x > 1`, `x != 0` and buf[x - 1]`.
//!
//!      Also handles `or`-short-circuit: `GUARD_IDENT (== 0 | < N) keyword_or`
//!      where `== 0` short-circuits leaving IDENT ≠ 0, and `< N` (N≥1) short-
//!      circuits leaving IDENT ≥ N ≥ 1.  Covers `len < 2 or arr[len - 1]`.
//!
//!   2. If/for/while-body guard (AST pre-pass, `collectGuardedRanges`):
//!      Scans `if_simple`/`if` nodes via `tree.fullIf`:
//!      • `IDENT (> N | >= N | !=) 0` in condition → records `then_expr` range.
//!      • `IDENT == 0` in condition → records `else_expr` range.
//!      Scans `for_simple`/`for` nodes via `tree.fullFor`:
//!      • Single input `K..N` with K ≥ 1 → capture ≥ 1, records body range.
//!        Covers `for (1..n) |i| arr[i-1]` and `for (2..n) |i| arr[i-1]`.
//!      • Single input is a literal array with all values > 0 → capture > 0.
//!        Covers `inline for ([_]usize{7,6,5,4,3,2,1}) |i| arr[i-1]`.
//!      Scans `while_simple`/`while_cont`/`while` nodes via `tree.fullWhile`:
//!      • `IDENT (> N | >= N | !=) 0` in condition → records body range.
//!        Covers `while (i > 0) { arr[i - 1] }` and `while (len > 0) { arr[len-1] }`.
//!      Token-range containment is exact for all body shapes.
//!
//!   3. Assert guard (window 50): scans inside `assert(...)` for
//!      `GUARD_IDENT (> | !=) 0` (simple or dotted), including compound
//!      conditions (`assert(a > 0 and b.len > 0)`) and OR-short-circuit
//!      forms (`assert(x == 0 or arr[x-1] < limit)`).
//!
//!   4. Early-exit guard (window 45): `if (GUARD == 0)` followed within 3
//!      tokens by `return`, `continue`, or `break`.  Covers
//!      `if (i == 0) continue; arr[i - 1]` in loop bodies.
//!
//!   5. Comptime context (window 5): `keyword_comptime` within 5 tokens of `[`.
//!      A comptime subscript is bounds-checked at compile time.
//!      Covers `comptime assert(fmt[fmt.len - 1] == '\n')`.

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const tokens = @import("../../ast/tokens.zig");
const value_range = @import("../../flow/value_range.zig");
const testing = @import("../../testing.zig");

const skipNestedFn = tokens.skipNestedFn;

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "index-minus-one-without-zero-guard";

/// File-level context built once per source file.  All slices are stable for
/// as long as the Ast lives, so they may be used as hash-map keys.
const FileCtx = struct {
    /// callee_name → field_name: functions that guarantee returned value's
    /// `.field.len >= 1`.  Built from `assert(X.FIELD.len >= 1)` near call sites.
    callee_nonempty: std.StringHashMapUnmanaged([]const u8),

    /// Struct fields that are monotone-increasing from a positive default:
    ///   - declared with `name : type = N,` where N ≥ 1
    ///   - every assignment in the file is `obj.name = @max(...)`
    /// Such fields are always ≥ 1 at runtime.
    monotone_pos: std.StringHashMapUnmanaged(void),

    fn build(gpa: std.mem.Allocator, tree: *const Ast) !FileCtx {
        var ctx: FileCtx = .{
            .callee_nonempty = .empty,
            .monotone_pos = .empty,
        };
        errdefer ctx.deinit(gpa);
        try ctx.fillCalleeNonEmpty(gpa, tree);
        try ctx.fillMonotonePos(gpa, tree);
        return ctx;
    }

    fn deinit(self: *FileCtx, gpa: std.mem.Allocator) void {
        self.callee_nonempty.deinit(gpa);
        self.monotone_pos.deinit(gpa);
    }

    /// Detect callee → field where callee guarantees .field.len ≥ 1.
    /// Scans for `const X = CALLEE(...)` followed by `assert(X.FIELD.len (>0|>=1|!=0))`.
    fn fillCalleeNonEmpty(self: *FileCtx, gpa: std.mem.Allocator, tree: *const Ast) !void {
        const ttags = tree.tokens.items(.tag);
        const n: u32 = @intCast(tree.tokens.len);
        var i: u32 = 0;
        while (i + 4 < n) : (i += 1) {
            if (ttags[i] != .keyword_const) continue;
            if (ttags[i + 1] != .identifier) continue;
            if (ttags[i + 2] != .equal) continue;
            if (ttags[i + 3] != .identifier) continue;
            if (ttags[i + 4] != .l_paren) continue;
            const local_name = tree.tokenSlice(i + 1);
            const callee_name = tree.tokenSlice(i + 3);
            const j_end: u32 = @min(i + 80, n -| 10);
            var j = i + 5;
            while (j < j_end) : (j += 1) {
                if (ttags[j] != .identifier) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(j), "assert")) continue;
                if (j + 8 >= n) break;
                if (ttags[j + 1] != .l_paren) continue;
                if (ttags[j + 2] != .identifier) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(j + 2), local_name)) continue;
                if (ttags[j + 3] != .period) continue;
                if (ttags[j + 4] != .identifier) continue;
                if (ttags[j + 5] != .period) continue;
                if (ttags[j + 6] != .identifier) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(j + 6), "len")) continue;
                const cmp = ttags[j + 7];
                const vt = j + 8;
                if (ttags[vt] != .number_literal) continue;
                const val = tree.tokenSlice(vt);
                const nonzero =
                    ((cmp == .angle_bracket_right or cmp == .bang_equal) and std.mem.eql(u8, val, "0")) or
                    (cmp == .angle_bracket_right_equal and std.mem.eql(u8, val, "1"));
                if (!nonzero) continue;
                const field_name = tree.tokenSlice(j + 4);
                try self.callee_nonempty.put(gpa, callee_name, field_name);
                break;
            }
        }
    }

    /// Detect struct fields that are monotone-increasing from a positive default.
    ///
    /// Phase 1 — find candidates: `FIELD : TYPE = N ,` where N ≥ 1.
    ///   Only simple single-identifier types (e.g. `usize`, `u32`) are matched.
    ///   The trailing `,` distinguishes struct fields from other `= N` patterns.
    ///
    /// Phase 2 — validate: every `. FIELD =` assignment in the file must be
    ///   followed by `@max(` (builtin).  Any other RHS disqualifies the field
    ///   (it could decrease the value below the default).
    ///
    /// Fields that pass both phases are always ≥ N ≥ 1 by induction:
    ///   base case = default N; step case = @max(expr, FIELD) ≥ FIELD ≥ N.
    fn fillMonotonePos(self: *FileCtx, gpa: std.mem.Allocator, tree: *const Ast) !void {
        const ttags = tree.tokens.items(.tag);
        const n: u32 = @intCast(tree.tokens.len);

        // Phase 1.
        var i: u32 = 0;
        while (i + 5 < n) : (i += 1) {
            if (ttags[i] != .identifier) continue;
            if (ttags[i + 1] != .colon) continue;
            if (ttags[i + 2] != .identifier) continue; // simple type (usize, u32, …)
            if (ttags[i + 3] != .equal) continue;
            if (ttags[i + 4] != .number_literal) continue;
            if (ttags[i + 5] != .comma) continue;
            const default_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(i + 4), 0) catch continue;
            if (default_val < 1) continue;
            const field_name = tree.tokenSlice(i);
            try self.monotone_pos.put(gpa, field_name, {});
        }

        // Phase 2 — remove any field that has a non-@max assignment anywhere.
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(gpa);
        var it = self.monotone_pos.keyIterator();
        while (it.next()) |key_ptr| {
            const field_name = key_ptr.*;
            var disqualified = false;
            var j: u32 = 0;
            while (j + 2 < n) : (j += 1) {
                // Look for `. FIELD =` (field assignment expression).
                if (ttags[j] != .period) continue;
                if (ttags[j + 1] != .identifier) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(j + 1), field_name)) continue;
                if (ttags[j + 2] != .equal) continue;
                // Ensure the `=` is not `==` (comparison).
                if (j + 3 < n and ttags[j + 3] == .equal) continue;
                // RHS must be `@max`.
                if (j + 3 >= n or
                    ttags[j + 3] != .builtin or
                    !std.mem.eql(u8, tree.tokenSlice(j + 3), "@max"))
                {
                    disqualified = true;
                    break;
                }
            }
            if (disqualified) try to_remove.append(gpa, field_name);
        }
        for (to_remove.items) |k| _ = self.monotone_pos.remove(k);
    }
};

/// Maps callee function name → field name for functions that guarantee the
/// returned value's `.field.len >= 1`.  Kept for type-alias clarity.

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .index_minus_one_without_zero_guard)) return;
    var ctx = try FileCtx.build(gpa, tree);
    defer ctx.deinit(gpa);
    var proto_buf: [1]Ast.Node.Index = undefined;
    var fns = tokens.iterFnDecls(tree);
    while (fns.next(&proto_buf)) |fn_entry| {
        try checkBody(gpa, tree, fn_entry.body, problems, &ctx, cache);
    }
}

fn checkBody(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body: Ast.Node.Index,
    problems: *std.ArrayListUnmanaged(Problem),
    ctx: *const FileCtx,
    cache: *file_cache_mod.FileCache,
) !void {
    const tags = tree.tokens.items(.tag);
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);

    if (first + 4 > last) return;

    // AST pre-pass: collect token ranges of if-bodies whose condition
    // contains a zero-guard on some identifier.  Used by `isInGuardedRange`.
    var guarded = try collectGuardedRanges(gpa, tree, first, last, ctx);
    defer guarded.deinit(gpa);

    var t: Ast.TokenIndex = first;
    while (t + 4 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }

        if (tags[t] != .l_bracket) continue;

        // Subscript inside a `comptime` expression is evaluated at compile
        // time; any OOB would be a compile error, not a runtime panic.
        if (hasComptimeContext(tags, t)) continue;

        // Form A: `[ identifier - 1 ]`
        //   t+0: l_bracket
        //   t+1: identifier
        //   t+2: minus
        //   t+3: number_literal "1"
        //   t+4: r_bracket
        if (tags[t + 1] == .identifier and
            tags[t + 2] == .minus and
            tags[t + 3] == .number_literal and
            std.mem.eql(u8, tree.tokenSlice(t + 3), "1") and
            tags[t + 4] == .r_bracket)
        {
            const idx_name = tree.tokenSlice(t + 1);
            if (hasAndGuard(tags, tree, t, &.{idx_name})) continue;
            if (hasOrGuard(tags, tree, t, &.{idx_name})) continue;
            if (isInGuardedRange(guarded.items, t, &.{idx_name})) continue;
            if (hasAssertGuard(tags, tree, t, &.{idx_name})) continue;
            if (hasEarlyReturnGuard(tags, tree, t, &.{idx_name})) continue;
            if (hasIncrementGuard(tags, tree, t, &.{idx_name})) continue;
            if (hasInitToOneGuard(tags, tree, t, &.{idx_name})) continue;
            // Sound value-range oracle: provably-nonzero index ⇒ `i - 1` cannot
            // underflow.  Catches dominating guards the token heuristics above
            // miss (cross-statement `if (i > 0) {...}`, early-return on zero,
            // positive-literal init) without their brittleness — the oracle
            // under-approximates, so it never suppresses a real underflow.
            if (value_range.provesNonzero(gpa, tree, body, idx_name, t, cache)) continue;
            try report(gpa, problems, tree, t, idx_name);
            continue;
        }

        // Form B: `[ identifier . identifier - 1 ]`
        //   t+0: l_bracket
        //   t+1: identifier
        //   t+2: period
        //   t+3: identifier
        //   t+4: minus
        //   t+5: number_literal "1"
        //   t+6: r_bracket
        if (t + 6 <= last and
            tags[t + 1] == .identifier and
            tags[t + 2] == .period and
            tags[t + 3] == .identifier and
            tags[t + 4] == .minus and
            tags[t + 5] == .number_literal and
            std.mem.eql(u8, tree.tokenSlice(t + 5), "1") and
            tags[t + 6] == .r_bracket)
        {
            const outer_name = tree.tokenSlice(t + 1);
            const idx_name = tree.tokenSlice(t + 3);
            // `constants.X` is a comptime namespace in Zig; subscripts are safe.
            if (std.mem.eql(u8, outer_name, "constants")) continue;
            if (hasAndGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (hasOrGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (isInGuardedRange(guarded.items, t, &.{ outer_name, idx_name })) continue;
            if (hasAssertGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (hasEarlyReturnGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (hasZeroAccessGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (hasIncrementGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (hasInitToOneGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            if (hasPriorArithmeticGuard(tags, tree, t, &.{ outer_name, idx_name })) continue;
            // Value-range oracle: when the index is `outer.len`, a dominating
            // proof that `outer` is non-empty makes `outer.len - 1` safe.
            if (std.mem.eql(u8, idx_name, "len") and
                value_range.provesNonempty(gpa, tree, body, outer_name, t, cache)) continue;
            try report(gpa, problems, tree, t, idx_name);
            continue;
        }

        // Form C: `[ identifier . identifier . len - 1 ]`
        //   t+0: l_bracket
        //   t+1: identifier (recv)
        //   t+2: period
        //   t+3: identifier (field)
        //   t+4: period
        //   t+5: identifier "len"
        //   t+6: minus
        //   t+7: number_literal "1"
        //   t+8: r_bracket
        if (t + 8 <= last and
            tags[t + 1] == .identifier and
            tags[t + 2] == .period and
            tags[t + 3] == .identifier and
            tags[t + 4] == .period and
            tags[t + 5] == .identifier and
            std.mem.eql(u8, tree.tokenSlice(t + 5), "len") and
            tags[t + 6] == .minus and
            tags[t + 7] == .number_literal and
            std.mem.eql(u8, tree.tokenSlice(t + 7), "1") and
            tags[t + 8] == .r_bracket)
        {
            const recv_name = tree.tokenSlice(t + 1);
            const field_name = tree.tokenSlice(t + 3);
            if (std.mem.eql(u8, recv_name, "constants")) continue;
            if (hasAndGuard(tags, tree, t, &.{ recv_name, field_name, "len" })) continue;
            if (hasOrGuard(tags, tree, t, &.{ recv_name, field_name, "len" })) continue;
            if (isInGuardedRange(guarded.items, t, &.{ recv_name, field_name, "len" })) continue;
            if (hasAssertGuard(tags, tree, t, &.{ recv_name, field_name, "len" })) continue;
            if (hasEarlyReturnGuard(tags, tree, t, &.{ recv_name, field_name, "len" })) continue;
            if (hasZeroAccessGuard(tags, tree, t, &.{ recv_name, field_name })) continue;
            // Value-range oracle: index is `recv.field.len`; a dominating proof
            // that container `recv.field` is non-empty makes `…len - 1` safe.
            // Build the container path as the exact source spelling (matches
            // the oracle's source-substring keys).
            {
                const starts = tree.tokens.items(.start);
                const path = tree.source[starts[t + 1] .. starts[t + 3] + tree.tokenSlice(t + 3).len];
                if (value_range.provesNonempty(gpa, tree, body, path, t, cache)) continue;
            }
            try reportC(gpa, problems, tree, t, recv_name, field_name);
            continue;
        }
    }
}

/// True when `keyword_comptime` appears within 5 tokens before `[`.
/// A subscript evaluated at compile time cannot cause a runtime OOB panic.
fn hasComptimeContext(tags: []const std.zig.Token.Tag, t: Ast.TokenIndex) bool {
    const window: u32 = 5;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] == .keyword_comptime) return true;
    }
    return false;
}

/// True for a decimal integer literal that is ≥ 0 (non-negative).
/// e.g. "0", "1", "42" → true.  Negative strings or non-decimal text → false.
fn isNonNegativeLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// True for a decimal integer literal that is ≥ 1 (strictly positive).
/// e.g. "1", "42" → true.  "0", negative, or non-decimal → false.
fn isPositiveLiteral(s: []const u8) bool {
    return isNonNegativeLiteral(s) and !std.mem.eql(u8, s, "0");
}

/// Returns true when a guard token sequence implying `IDENT ≥ 1` is present.
/// Specifically, checks whether the three tokens at [ident_tok, cmp_tok, val_tok]
/// form one of:
///   IDENT >  N  (N ≥ 0 → IDENT ≥ 1)
///   IDENT >= N  (N ≥ 1 → IDENT ≥ 1)
///   IDENT != 0
///   IDENT >  OTHER_IDENT  (for usize: OTHER_IDENT ≥ 0, so IDENT ≥ 1)
///   IDENT >= OTHER_IDENT  (for usize: IDENT > 0, so IDENT ≥ 1)
///   IDENT != OTHER_IDENT  (variable comparison — weaker, accepted for practicality)
fn isPositiveGuardTriple(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    ident_tok: Ast.TokenIndex,
    cmp_tok: Ast.TokenIndex,
    val_tok: Ast.TokenIndex,
) bool {
    if (tags[ident_tok] != .identifier) return false;
    if (tags[val_tok] == .number_literal) {
        const val = tree.tokenSlice(val_tok);
        return switch (tags[cmp_tok]) {
            .angle_bracket_right => isNonNegativeLiteral(val), // x > N (N≥0)
            .angle_bracket_right_equal => isPositiveLiteral(val), // x >= N (N≥1)
            .bang_equal => std.mem.eql(u8, val, "0"), // x != 0
            else => false,
        };
    }
    // Variable-vs-variable comparison: `A > B` where both are usize.
    // Since usize ≥ 0 always, A > B implies A ≥ 1.  Sound for unsigned types.
    // Also accept `A >= B` and `A != B` as positive-positional guards.
    if (tags[val_tok] == .identifier) {
        return tags[cmp_tok] == .angle_bracket_right or
            tags[cmp_tok] == .angle_bracket_right_equal or
            tags[cmp_tok] == .bang_equal;
    }
    return false;
}

/// Returns true when a same-expression `and`-guard for one of `guard_names` is
/// present in the 15 tokens immediately before the `[` at position `t`.
///
/// Matched token pattern (reading backward from `t`):
///   ... GUARD_IDENT (> | >= | !=) VALUE keyword_and ARRAY_IDENT [t]
///
/// VALUE is a decimal integer: `> N` (any N≥0) or `>= N` (N≥1) or `!= 0`.
/// Covers `x > 0 and buf[x - 1]`, `x >= 1 and buf[x - 1]`, `x > 1 and buf[x - 1]`.
fn hasAndGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 5) return false;
    // Window 30: large enough for compound OR conditions like
    // `while (end > 0 and (arr[end-1] == x or arr[end-1] == y or arr[end-1] == z))`
    // where late subscripts are ~25+ tokens from the `and`.
    const window: u32 = 30;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .keyword_and) continue;
        if (k < 3) continue;
        // Standard 3-token guard: GUARD_IDENT cmp VALUE
        if (isPositiveGuardTriple(tags, tree, k - 3, k - 2, k - 1)) {
            const guard_id = tree.tokenSlice(k - 3);
            for (guard_names) |gn| {
                if (std.mem.eql(u8, guard_id, gn)) return true;
            }
        }
        // Extended: `GUARD >= IDENT + N keyword_and` (N ≥ 1).
        // Since IDENT is unsigned (≥ 0) and N ≥ 1, GUARD ≥ IDENT + N ≥ 1.
        // Token layout: GUARD(k-5) >=(k-4) IDENT(k-3) +(k-2) N(k-1) and(k).
        if (k >= 5 and
            tags[k - 5] == .identifier and
            tags[k - 4] == .angle_bracket_right_equal and
            tags[k - 3] == .identifier and
            tags[k - 2] == .plus and
            tags[k - 1] == .number_literal)
        {
            const n_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(k - 1), 0) catch 0;
            if (n_val >= 1) {
                const guard_id2 = tree.tokenSlice(k - 5);
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, guard_id2, gn)) return true;
                }
            }
        }
    }
    return false;
}

/// Returns true when a same-expression `or`-guard for one of `guard_names` is
/// present in the 15 tokens immediately before the `[` at position `t`.
///
/// Two matched patterns (reading backward from `t`):
///   ... GUARD_IDENT == 0 keyword_or ARRAY_IDENT [t]
///       (i == 0 disjunct short-circuits; subscript only evaluates when i != 0)
///   ... GUARD_IDENT < N keyword_or ARRAY_IDENT [t]  (N ≥ 1)
///       (len < 2 disjunct short-circuits; subscript only evaluates when len ≥ N ≥ 1)
fn hasOrGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 5) return false;
    const window: u32 = 15;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .keyword_or) continue;
        if (k < 3) continue;
        if (tags[k - 1] != .number_literal) continue;
        const val = tree.tokenSlice(k - 1);
        const cmp = tags[k - 2];
        // IDENT == 0 or: subscript guarded because evaluated only when IDENT != 0
        // IDENT < N or (N≥1): subscript guarded because evaluated only when IDENT ≥ N ≥ 1
        const is_guard = (cmp == .equal_equal and std.mem.eql(u8, val, "0")) or
            (cmp == .angle_bracket_left and isPositiveLiteral(val));
        if (!is_guard) continue;
        if (tags[k - 3] != .identifier) continue;
        const guard_id = tree.tokenSlice(k - 3);
        for (guard_names) |gn| {
            if (std.mem.eql(u8, guard_id, gn)) return true;
        }
    }
    return false;
}

/// One entry from the AST pre-pass: guard identifiers + the EXACT token range
/// of the corresponding if-body (`then_expr`).  A subscript `[` that falls
/// within [first, last] is structurally inside the if-body.
///
/// When `pair` is true, ALL names[0..n] must appear in the subscript's
/// check_names (AND semantics).  Used for dotted guards like `a.len > 0`,
/// where suppression requires the subscript to use BOTH `a` and `len`.
/// When `pair` is false, ANY matching name suffices (OR semantics).
const GuardedRange = struct {
    names: [3][]const u8,
    n: u8,
    pair: bool,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
};

/// Walk all AST nodes in [body_first, body_last].
///
/// `if_simple`/`if` nodes:
///   • Condition `IDENT (> | !=) 0` → record `then_expr` range.
///   • Condition `IDENT == 0`       → record `else_expr` range.
///
/// `for_simple`/`for` nodes with a single iterable:
///   • Iterable is a range `K..N` with K ≥ 1 (e.g. `1..len`, `2..max+1`):
///     the capture variable is guaranteed ≥ 1 inside the body.
///   • Iterable is a literal array `{v1, v2, …}` where all vᵢ > 0
///     (e.g. `inline for ([_]usize{7,6,5,4,3,2,1}) |i|`):
///     the capture variable takes only positive values.
///
/// In both `for` cases the exact token range of `then_expr` (the loop body)
/// is recorded as a guarded range for the capture variable name.
fn collectGuardedRanges(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body_first: Ast.TokenIndex,
    body_last: Ast.TokenIndex,
    ctx: *const FileCtx,
) !std.ArrayListUnmanaged(GuardedRange) {
    var out: std.ArrayListUnmanaged(GuardedRange) = .empty;
    const ttags = tree.tokens.items(.tag);
    const ntags = tree.nodes.items(.tag);

    var ni: u32 = 1;
    while (ni < tree.nodes.len) : (ni += 1) {
        const ntag = ntags[ni];
        // Early tag filter: only for/if/while nodes emit GuardedRanges.
        // Skipping firstToken/lastToken for all other nodes avoids
        // O(N_nodes × N_fns) expensive AST traversal.
        switch (ntag) {
            .for_simple, .@"for", .if_simple, .@"if",
            .while_simple, .while_cont, .@"while" => {},
            else => continue,
        }
        const node: Ast.Node.Index = @enumFromInt(ni);

        const nf = tree.firstToken(node);
        const nl = tree.lastToken(node);
        if (nf < body_first or nl > body_last) continue;

        // ── For-loop analysis ─────────────────────────────────────────────
        if (ntag == .for_simple or ntag == .@"for") {
            const fd = tree.fullFor(node) orelse continue;
            // Only handle single-iterable for-loops.
            if (fd.ast.inputs.len != 1) continue;
            const input = fd.ast.inputs[0];

            // payload_token points directly to the first capture identifier
            // (not the preceding `|`).  Skip `*` for pointer captures.
            var pt = fd.payload_token;
            if (pt < tree.tokens.len and ttags[pt] == .asterisk) pt += 1;
            if (pt >= tree.tokens.len or ttags[pt] != .identifier) continue;
            const capture = tree.tokenSlice(pt);

            const input_first = tree.firstToken(input);
            var guarded = false;

            // Case A: range `K..N` where K ≥ 1 (integer literal).
            //   Capture iterates K, K+1, …, N-1 — all ≥ 1.
            if (ttags[input_first] == .number_literal and
                input_first + 1 < tree.tokens.len and
                ttags[input_first + 1] == .ellipsis2)
            {
                const start_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(input_first), 0) catch 0;
                if (start_val >= 1) guarded = true;
            }

            // Case B: literal array `{v1, v2, …}` with all vᵢ > 0.
            if (!guarded) guarded = isAllPositiveLiterals(tree, ttags, input);

            if (guarded) {
                try out.append(gpa, .{
                    .names = .{ capture, "", "" },
                    .n = 1,
                    .pair = false,
                    .first = tree.firstToken(fd.ast.then_expr),
                    .last = tree.lastToken(fd.ast.then_expr),
                });
            }
            continue;
        }

        // ── While-node analysis ───────────────────────────────────────────
        // `while (IDENT > 0)`, `while (IDENT >= 1)`, `while (IDENT != 0)`
        // guarantee IDENT ≥ 1 throughout the loop body.
        // Also handles dotted: `while (a.len > 0)`.
        if (ntag == .while_simple or ntag == .while_cont or ntag == .@"while") {
            const wd = tree.fullWhile(node) orelse continue;
            const wf = tree.firstToken(wd.ast.cond_expr);
            const wl = tree.lastToken(wd.ast.cond_expr);
            const body_first_w = tree.firstToken(wd.ast.then_expr);
            const body_last_w = tree.lastToken(wd.ast.then_expr);
            var ct2 = wf;
            while (ct2 <= wl) : (ct2 += 1) {
                if (ttags[ct2] != .identifier) continue;
                // Dotted: OUTER . INNER cmp VALUE
                if (ct2 + 4 <= wl and
                    ttags[ct2 + 1] == .period and
                    ttags[ct2 + 2] == .identifier and
                    ttags[ct2 + 4] == .number_literal)
                {
                    if (isPositiveGuardTriple(ttags, tree, ct2, ct2 + 3, ct2 + 4)) {
                        try out.append(gpa, .{
                            .names = .{ tree.tokenSlice(ct2), tree.tokenSlice(ct2 + 2), "" },
                            .n = 2,
                            .pair = true,
                            .first = body_first_w,
                            .last = body_last_w,
                        });
                        ct2 += 4;
                        continue;
                    }
                }
                // Simple: IDENT cmp VALUE
                if (ct2 + 2 <= wl and ttags[ct2 + 2] == .number_literal) {
                    if (isPositiveGuardTriple(ttags, tree, ct2, ct2 + 1, ct2 + 2)) {
                        try out.append(gpa, .{
                            .names = .{ tree.tokenSlice(ct2), "", "" },
                            .n = 1,
                            .pair = false,
                            .first = body_first_w,
                            .last = body_last_w,
                        });
                        ct2 += 2;
                        continue;
                    }
                }
            }
            continue;
        }

        // ── If-node analysis ──────────────────────────────────────────────
        if (ntag != .if_simple and ntag != .@"if") continue;

        const ifd = tree.fullIf(node) orelse continue;
        const cf = tree.firstToken(ifd.ast.cond_expr);
        const cl = tree.lastToken(ifd.ast.cond_expr);

        // Detect `X.METHOD_OR_NULL()` with a payload binding `|...|`.
        // When the condition is a nullable-returning method (e.g. getLastOrNull,
        // popOrNull), non-null means the container is non-empty.
        // Covers `if (result.getLastOrNull()) |prev| { ... result.items[result.items.len-1] }`.
        if (ifd.payload_token != null) {
            var ct2 = cf;
            while (ct2 + 4 <= cl) : (ct2 += 1) {
                if (ttags[ct2] != .identifier) continue;
                if (ttags[ct2 + 1] != .period) continue;
                if (ttags[ct2 + 2] != .identifier) continue;
                if (!std.mem.endsWith(u8, tree.tokenSlice(ct2 + 2), "OrNull")) continue;
                if (ttags[ct2 + 3] != .l_paren) continue;
                if (ttags[ct2 + 4] != .r_paren) continue;
                try out.append(gpa, .{
                    .names = .{ tree.tokenSlice(ct2), "", "" },
                    .n = 1,
                    .pair = false,
                    .first = tree.firstToken(ifd.ast.then_expr),
                    .last = tree.lastToken(ifd.ast.then_expr),
                });
                break;
            }
        }

        // Emit one GuardedRange per condition pattern found (not one aggregate).
        // Dotted patterns set pair=true so isInGuardedRange requires BOTH names.
        var ct = cf;
        while (ct <= cl) : (ct += 1) {
            if (ttags[ct] != .identifier) continue;
            // Dotted: OUTER . INNER cmp VALUE
            if (ct + 4 <= cl and
                ttags[ct + 1] == .period and
                ttags[ct + 2] == .identifier and
                ttags[ct + 4] == .number_literal)
            {
                const cmp = ttags[ct + 3];
                const val = tree.tokenSlice(ct + 4);
                const outer = tree.tokenSlice(ct);
                const inner = tree.tokenSlice(ct + 2);
                if (isPositiveGuardTriple(ttags, tree, ct, ct + 3, ct + 4)) {
                    try out.append(gpa, .{
                        .names = .{ outer, inner, "" },
                        .n = 2,
                        .pair = true,
                        .first = tree.firstToken(ifd.ast.then_expr),
                        .last = tree.lastToken(ifd.ast.then_expr),
                    });
                } else if (cmp == .equal_equal and std.mem.eql(u8, val, "0")) {
                    if (ifd.ast.else_expr.unwrap()) |else_node| {
                        try out.append(gpa, .{
                            .names = .{ outer, inner, "" },
                            .n = 2,
                            .pair = true,
                            .first = tree.firstToken(else_node),
                            .last = tree.lastToken(else_node),
                        });
                    }
                }
                ct += 4;
                continue;
            }
            // Simple: IDENT cmp VALUE
            if (ct + 2 <= cl and ttags[ct + 2] == .number_literal) {
                const cmp = ttags[ct + 1];
                const val = tree.tokenSlice(ct + 2);
                const ident = tree.tokenSlice(ct);
                if (isPositiveGuardTriple(ttags, tree, ct, ct + 1, ct + 2)) {
                    try out.append(gpa, .{
                        .names = .{ ident, "", "" },
                        .n = 1,
                        .pair = false,
                        .first = tree.firstToken(ifd.ast.then_expr),
                        .last = tree.lastToken(ifd.ast.then_expr),
                    });
                } else if (cmp == .equal_equal and std.mem.eql(u8, val, "0")) {
                    if (ifd.ast.else_expr.unwrap()) |else_node| {
                        try out.append(gpa, .{
                            .names = .{ ident, "", "" },
                            .n = 1,
                            .pair = false,
                            .first = tree.firstToken(else_node),
                            .last = tree.lastToken(else_node),
                        });
                    }
                }
                ct += 2;
                continue;
            }
            // IDENT >= IDENT + N (N ≥ 1): since the RHS IDENT is unsigned (≥ 0),
            // this implies IDENT ≥ N ≥ 1 — record then_expr as a guarded range.
            if (ct + 4 <= cl and
                ttags[ct + 1] == .angle_bracket_right_equal and
                ttags[ct + 2] == .identifier and
                ttags[ct + 3] == .plus and
                ttags[ct + 4] == .number_literal)
            {
                const n_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(ct + 4), 0) catch 0;
                if (n_val >= 1) {
                    try out.append(gpa, .{
                        .names = .{ tree.tokenSlice(ct), "", "" },
                        .n = 1,
                        .pair = false,
                        .first = tree.firstToken(ifd.ast.then_expr),
                        .last = tree.lastToken(ifd.ast.then_expr),
                    });
                }
                ct += 4;
                continue;
            }
        }

        // ── Inverted early-exit: `if (IDENT < IDENT + N) exit; rest_guarded` ──
        // When the condition is `IDENT < OTHER + N` (N ≥ 1), the then_expr
        // exits (return/break/continue), and there is no else branch, execution
        // past the if guarantees IDENT ≥ OTHER + N ≥ N ≥ 1.
        // Record [after_if, body_last] as guarded for IDENT.
        //
        // Covers patterns like:
        //   `if (end < start + 2) return null;` → end ≥ 2 after
        //   `if (rparen < t + 4) continue;`    → rparen ≥ 4 after
        if (ifd.ast.else_expr == .none) {
            const then_first_tag = ttags[tree.firstToken(ifd.ast.then_expr)];
            const is_exit_body = then_first_tag == .keyword_return or
                then_first_tag == .keyword_break or
                then_first_tag == .keyword_continue;
            if (is_exit_body) {
                var ct2 = cf;
                while (ct2 + 4 <= cl) : (ct2 += 1) {
                    if (ttags[ct2] != .identifier) continue;
                    if (ttags[ct2 + 1] != .angle_bracket_left) continue;
                    if (ttags[ct2 + 2] != .identifier) continue;
                    if (ttags[ct2 + 3] != .plus) continue;
                    if (ttags[ct2 + 4] != .number_literal) continue;
                    const n_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(ct2 + 4), 0) catch 0;
                    if (n_val < 1) continue;
                    const after_if = tree.lastToken(node) + 1;
                    if (after_if <= body_last) {
                        try out.append(gpa, .{
                            .names = .{ tree.tokenSlice(ct2), "", "" },
                            .n = 1,
                            .pair = false,
                            .first = after_if,
                            .last = body_last,
                        });
                    }
                    ct2 += 4;
                }
            }
        }
    }

    // ── Cross-pass 1: for-input slice-to-len-minus-one ────────────────────
    // For any for-loop input of the form `IDENT [ expr .. IDENT . len - 1 ]`,
    // `IDENT.len ≥ 1` is required for the slice bound to be valid.
    // Record the entire function body as guarded for (IDENT, len).
    // Covers `for (entries[0..entries.len - 1], ...) |...|` → entries.len ≥ 1.
    {
        var ni2: u32 = 1;
        while (ni2 < tree.nodes.len) : (ni2 += 1) {
            const ntag2 = ntags[ni2];
            if (ntag2 != .for_simple and ntag2 != .@"for") continue;
            const node2: Ast.Node.Index = @enumFromInt(ni2);
            const nf2 = tree.firstToken(node2);
            const nl2 = tree.lastToken(node2);
            if (nf2 < body_first or nl2 > body_last) continue;
            const fd2 = tree.fullFor(node2) orelse continue;
            for (fd2.ast.inputs) |inp2| {
                // Input must start with an identifier (the array being sliced).
                const inp_first = tree.firstToken(inp2);
                const inp_last = tree.lastToken(inp2);
                if (ttags[inp_first] != .identifier) continue;
                const arr = tree.tokenSlice(inp_first);
                // Scan for `.. arr . len - 1` inside the input's token range.
                var st2 = inp_first + 1;
                while (st2 + 5 <= inp_last) : (st2 += 1) {
                    if (ttags[st2] != .ellipsis2) continue;
                    if (ttags[st2 + 1] != .identifier) continue;
                    if (!std.mem.eql(u8, tree.tokenSlice(st2 + 1), arr)) continue;
                    if (ttags[st2 + 2] != .period) continue;
                    if (ttags[st2 + 3] != .identifier or
                        !std.mem.eql(u8, tree.tokenSlice(st2 + 3), "len")) continue;
                    if (ttags[st2 + 4] != .minus) continue;
                    if (st2 + 5 > inp_last or
                        ttags[st2 + 5] != .number_literal or
                        !std.mem.eql(u8, tree.tokenSlice(st2 + 5), "1")) continue;
                    // Found `.. arr.len - 1` → arr.len ≥ 1 throughout the body.
                    try out.append(gpa, .{
                        .names = .{ arr, "len", "" },
                        .n = 2,
                        .pair = true,
                        .first = body_first,
                        .last = body_last,
                    });
                    break;
                }
            }
        }
    }

    // ── Cross-pass 2: function-wide dotted assert scan ─────────────────────
    // Scan the ENTIRE function body for `assert ( OUTER . INNER (> | !=) 0 )`
    // (dotted form only — bare identifiers are too generic).
    // Records the full body as guarded; handles asserts that are far from the
    // subscript in large functions, acting as function-entry preconditions.
    {
        var st3 = body_first;
        while (st3 + 7 <= body_last) : (st3 += 1) {
            if (ttags[st3] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(st3), "assert")) continue;
            if (ttags[st3 + 1] != .l_paren) continue;
            // Dotted: assert ( OUTER . INNER cmp 0 )
            if (ttags[st3 + 2] == .identifier and
                ttags[st3 + 3] == .period and
                ttags[st3 + 4] == .identifier and
                ttags[st3 + 6] == .number_literal and
                std.mem.eql(u8, tree.tokenSlice(st3 + 6), "0"))
            {
                const cmp3 = ttags[st3 + 5];
                if (cmp3 == .angle_bracket_right or cmp3 == .bang_equal) {
                    const outer3 = tree.tokenSlice(st3 + 2);
                    const inner3 = tree.tokenSlice(st3 + 4);
                    try out.append(gpa, .{
                        .names = .{ outer3, inner3, "" },
                        .n = 2,
                        .pair = true,
                        .first = body_first,
                        .last = body_last,
                    });
                }
            }
        }
    }

    // ── Cross-pass 3: callee postcondition — non-empty slice field ─────────────
    // For each `const LOCAL = CALLEE(...)` in the function body where CALLEE is
    // in the file-level callee_nonempty map (inferred from `assert(X.F.len >= 1)`
    // patterns in other functions), record the body from that point on as guarded
    // for (LOCAL, FIELD) pair.
    // Covers `const headers_a = message_body_as_view_headers(...)` where
    // verify_message() has `assert(headers.slice.len >= 1)`.
    {
        var ci = body_first;
        while (ci + 4 <= body_last) : (ci += 1) {
            if (ttags[ci] != .keyword_const) continue;
            if (ttags[ci + 1] != .identifier) continue;
            if (ttags[ci + 2] != .equal) continue;
            if (ttags[ci + 3] != .identifier) continue;
            if (ttags[ci + 4] != .l_paren) continue;
            const local_name = tree.tokenSlice(ci + 1);
            const callee_name = tree.tokenSlice(ci + 3);
            if (ctx.callee_nonempty.get(callee_name)) |field_name| {
                try out.append(gpa, .{
                    .names = .{ local_name, field_name, "" },
                    .n = 2,
                    .pair = true,
                    .first = ci,
                    .last = body_last,
                });
            }
        }
    }

    // ── Cross-pass 4: alloc-with-size-plus-N ─────────────────────────────────
    // `const LOCAL = try (anything).alloc(TYPE, EXPR + N)` where N ≥ 1 guarantees
    // LOCAL.len = EXPR + N ≥ 1 (since EXPR is usize ≥ 0 and +N ≥ 1).
    // Covers `const argv = try gpa.alloc([]const u8, cli.len + 1)` → argv.len ≥ 1.
    {
        var ci = body_first;
        while (ci + 4 <= body_last) : (ci += 1) {
            if (ttags[ci] != .keyword_const) continue;
            if (ttags[ci + 1] != .identifier) continue;
            if (ttags[ci + 2] != .equal) continue;
            if (ttags[ci + 3] != .keyword_try) continue;
            const local_name = tree.tokenSlice(ci + 1);
            // Find `alloc (` within the next 60 tokens.
            var alloc_paren: u32 = 0;
            {
                var j = ci + 4;
                const j_end = @min(ci + 60, body_last);
                while (j + 1 <= j_end) : (j += 1) {
                    if (ttags[j] == .identifier and
                        std.mem.eql(u8, tree.tokenSlice(j), "alloc") and
                        ttags[j + 1] == .l_paren)
                    {
                        alloc_paren = j + 1;
                        break;
                    }
                }
            }
            if (alloc_paren == 0) continue;
            // Track depth to find the last argument of alloc(...).
            var depth: u32 = 1;
            var last_arg_start: u32 = alloc_paren + 1;
            var close_paren: u32 = 0;
            {
                var k = alloc_paren + 1;
                while (k <= body_last) : (k += 1) {
                    switch (ttags[k]) {
                        .l_paren => depth += 1,
                        .r_paren => {
                            depth -= 1;
                            if (depth == 0) { close_paren = k; break; }
                        },
                        .comma => if (depth == 1) { last_arg_start = k + 1; },
                        else => {},
                    }
                }
            }
            if (close_paren == 0) continue;
            // Scan last argument [last_arg_start, close_paren) for `+ N` where N ≥ 1.
            var found = false;
            {
                var m = last_arg_start;
                while (m + 1 < close_paren) : (m += 1) {
                    if (ttags[m] != .plus) continue;
                    if (ttags[m + 1] != .number_literal) continue;
                    const n_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(m + 1), 0) catch continue;
                    if (n_val >= 1) { found = true; break; }
                }
            }
            if (!found) continue;
            try out.append(gpa, .{
                .names = .{ local_name, "", "" },
                .n = 1,
                .pair = false,
                .first = ci,
                .last = body_last,
            });
        }
    }

    // ── Monotone-positive field guards ────────────────────────────────────────
    // Fields detected as monotone-increasing-from-positive (struct default ≥ 1,
    // only @max assignments) are always ≥ 1 at any call site.
    // Emit a body-wide guarded range for each such field name so that subscripts
    // like `arr[obj.FIELD - 1]` where FIELD is in the set are suppressed.
    {
        var it = ctx.monotone_pos.keyIterator();
        while (it.next()) |key_ptr| {
            try out.append(gpa, .{
                .names = .{ key_ptr.*, "", "" },
                .n = 1,
                .pair = false,
                .first = body_first,
                .last = body_last,
            });
        }
    }

    return out;
}

/// True when `node` is an array-init literal whose element list (between
/// `{` and `}`) contains only positive integer literals (no zero, no
/// variable references).  Handles all `array_init*` node variants.
fn isAllPositiveLiterals(
    tree: *const Ast,
    ttags: []const std.zig.Token.Tag,
    node: Ast.Node.Index,
) bool {
    const ntag = tree.nodeTag(node);
    switch (ntag) {
        .array_init,
        .array_init_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => {},
        else => return false,
    }
    // Find the opening `{` in the node's token range.
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var brace: ?Ast.TokenIndex = null;
    var t = first;
    while (t <= last) : (t += 1) {
        if (ttags[t] == .l_brace) { brace = t; break; }
    }
    const open = brace orelse return false;
    // Scan element tokens between `{` and `}`.
    var has_elem = false;
    t = open + 1;
    while (t < last) : (t += 1) {
        switch (ttags[t]) {
            .number_literal => {
                const val = std.fmt.parseUnsigned(u64, tree.tokenSlice(t), 0) catch return false;
                if (val == 0) return false;
                has_elem = true;
            },
            .comma, .r_brace => {},
            else => return false, // identifier, operator, etc. → not a pure literal
        }
    }
    return has_elem;
}

/// True when the subscript `[` at `t` is inside a guarded if-body AND
/// the guard names match check_names according to the range's matching mode:
///   pair=false: any name in names[0..n] matches any name in check_names (OR)
///   pair=true:  ALL names in names[0..n] must appear in check_names (AND)
///               Used for dotted guards like `a.len > 0` to avoid suppressing
///               `b[b.len-1]` when only "len" coincidentally matches.
fn isInGuardedRange(
    ranges: []const GuardedRange,
    t: Ast.TokenIndex,
    check_names: []const []const u8,
) bool {
    for (ranges) |r| {
        if (t < r.first or t > r.last) continue;
        if (r.pair) {
            // AND semantics: every name in the guard must appear in check_names.
            var all_found = true;
            for (r.names[0..r.n]) |gn| {
                var found = false;
                for (check_names) |cn| {
                    if (std.mem.eql(u8, cn, gn)) { found = true; break; }
                }
                if (!found) { all_found = false; break; }
            }
            if (all_found) return true;
        } else {
            // OR semantics: any matching name is enough.
            for (check_names) |cn| {
                for (r.names[0..r.n]) |gn| {
                    if (std.mem.eql(u8, cn, gn)) return true;
                }
            }
        }
    }
    return false;
}

/// Returns true when `assert(...)` within 30 tokens before `[` contains
/// `GUARD_IDENT (> | !=) 0` anywhere inside the call — including compound
/// conditions like `assert(a > 0 and b.len > 0)` and OR-short-circuit forms
/// like `assert(x == 0 or arr[x - 1] < limit)`.
///
/// Scans up to 24 tokens inside the `assert(` for any simple or dotted
/// zero-guard pattern, stopping at the first `r_paren` at depth 0.
fn hasAssertGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 6) return false;
    const window: u32 = 50;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k), "assert")) continue;
        if (k + 1 >= t or tags[k + 1] != .l_paren) continue;

        // Scan inside assert( ... ) for any IDENT (> | !=) 0 pattern.
        // Stop at the first unbalanced `)` or after 26 tokens.
        // IMPORTANT: check the dotted pattern FIRST and advance past it so the
        // inner identifier (e.g. "len" in `a.len > 0`) is not then matched as a
        // standalone simple-ident guard on a subsequent iteration.
        var depth: u32 = 1;
        var ct = k + 2;
        while (ct < t and ct < k + 26) : (ct += 1) {
            if (tags[ct] == .l_paren) { depth += 1; continue; }
            if (tags[ct] == .r_paren) {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) break;
                continue;
            }
            if (tags[ct] != .identifier) continue;

            // Dotted: OUTER . INNER (> | !=) 0
            // Require BOTH outer AND inner to appear in guard_names.  Skip past
            // the whole 5-token pattern regardless of match to prevent the
            // inner identifier from being matched as a simple guard later.
            if (ct + 4 < t and
                tags[ct + 1] == .period and
                tags[ct + 2] == .identifier and
                (tags[ct + 3] == .angle_bracket_right or tags[ct + 3] == .bang_equal) and
                tags[ct + 4] == .number_literal and
                std.mem.eql(u8, tree.tokenSlice(ct + 4), "0"))
            {
                const outer_id = tree.tokenSlice(ct);
                const inner_id = tree.tokenSlice(ct + 2);
                var has_outer = false;
                var has_inner = false;
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, outer_id, gn)) has_outer = true;
                    if (std.mem.eql(u8, inner_id, gn)) has_inner = true;
                }
                if (has_outer and has_inner) return true;
                ct += 4; // skip `.INNER cmp 0`; loop adds 1 more
                continue;
            }

            // Simple: IDENT (> | !=) 0
            if (ct + 2 < t and
                (tags[ct + 1] == .angle_bracket_right or tags[ct + 1] == .bang_equal) and
                tags[ct + 2] == .number_literal and
                std.mem.eql(u8, tree.tokenSlice(ct + 2), "0"))
            {
                const guard_id = tree.tokenSlice(ct);
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, guard_id, gn)) return true;
                }
            }

            // OR-short-circuit: `IDENT == 0 keyword_or` — the RHS of the `or`
            // is only evaluated when IDENT != 0, so subscripts in the RHS are safe.
            // Covers `assert(offset == 0 or arr[offset - 1] < key)`.
            if (ct + 3 < t and
                tags[ct + 1] == .equal_equal and
                tags[ct + 2] == .number_literal and
                std.mem.eql(u8, tree.tokenSlice(ct + 2), "0") and
                tags[ct + 3] == .keyword_or)
            {
                const guard_id = tree.tokenSlice(ct);
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, guard_id, gn)) return true;
                }
            }
        }
    }
    return false;
}

/// Returns true when an early-return guard `if (GUARD == 0) return …`
/// precedes the subscript at `t` within 45 tokens.
///
/// The guard ensures execution only reaches `[` when GUARD != 0.
/// Semicolons between the return statement and `[` are allowed.
///
/// Matched patterns:
///   Simple: `if ( GUARD_IDENT == 0 ) keyword_return`  (return within 3 tok of `)`)
///   Dotted: `if ( OUTER . INNER == 0 ) keyword_return`
fn hasEarlyReturnGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 8) return false;
    const window: u32 = 45;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .keyword_if) continue;

        // Simple: `if ( GUARD_IDENT == 0 ) keyword_return`
        //   condition closes at k+5; return must appear within 3 tokens of it.
        if (k + 6 < t and
            tags[k + 1] == .l_paren and
            tags[k + 2] == .identifier and
            tags[k + 3] == .equal_equal and
            tags[k + 4] == .number_literal and
            std.mem.eql(u8, tree.tokenSlice(k + 4), "0") and
            tags[k + 5] == .r_paren)
        {
            if (hasExitWithin(tags, k + 6, k + 9, t)) {
                const guard_id = tree.tokenSlice(k + 2);
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, guard_id, gn)) return true;
                }
            }
        }

        // Dotted: `if ( OUTER . INNER == 0 ) keyword_return`
        //   condition closes at k+7; return within 3 tokens.
        if (k + 8 < t and
            tags[k + 1] == .l_paren and
            tags[k + 2] == .identifier and
            tags[k + 3] == .period and
            tags[k + 4] == .identifier and
            tags[k + 5] == .equal_equal and
            tags[k + 6] == .number_literal and
            std.mem.eql(u8, tree.tokenSlice(k + 6), "0") and
            tags[k + 7] == .r_paren)
        {
            if (hasExitWithin(tags, k + 8, k + 11, t)) {
                const outer_id = tree.tokenSlice(k + 2);
                const inner_id = tree.tokenSlice(k + 4);
                var has_outer = false;
                var has_inner = false;
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, outer_id, gn)) has_outer = true;
                    if (std.mem.eql(u8, inner_id, gn)) has_inner = true;
                }
                if (has_outer and has_inner) return true;
            }
        }

        // Compound `<=` early-exit: `if (GUARD <= ... or ...) return/break/continue`.
        // For unsigned GUARD, `GUARD <= anything` is satisfied when GUARD == 0
        // (0 ≤ any unsigned value).  After the early-exit, GUARD ≥ 1 is guaranteed.
        // Scan forward from the opening `(` to find the matching `)`, then check
        // for a return/break/continue within 3 tokens.
        if (k + 3 < t and
            tags[k + 1] == .l_paren and
            tags[k + 2] == .identifier and
            tags[k + 3] == .angle_bracket_left_equal)
        {
            const guard_id = tree.tokenSlice(k + 2);
            var matched = false;
            for (guard_names) |gn| {
                if (std.mem.eql(u8, guard_id, gn)) { matched = true; break; }
            }
            if (matched) {
                // Walk forward to find the closing `)`.
                var depth: u32 = 1;
                var j: Ast.TokenIndex = k + 2;
                while (j < t and j < k + 60) : (j += 1) {
                    if (tags[j] == .l_paren) depth += 1 else if (tags[j] == .r_paren) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (depth == 0 and hasExitWithin(tags, j + 1, j + 4, t)) return true;
            }
        }

        // Cross-variable `<` early-exit: `if (GUARD < OTHER + N) return/break/continue`
        // where N >= 1.  After the early-exit, GUARD >= OTHER + N >= N >= 1.
        // Pattern: `if ( GUARD_ID < OTHER_ID + N_LIT ) exit`
        if (k + 8 < t and
            tags[k + 1] == .l_paren and
            tags[k + 2] == .identifier and
            tags[k + 3] == .angle_bracket_left and
            tags[k + 4] == .identifier and
            tags[k + 5] == .plus and
            tags[k + 6] == .number_literal and
            tags[k + 7] == .r_paren)
        {
            const n_val = std.fmt.parseUnsigned(u64, tree.tokenSlice(k + 6), 10) catch 0;
            if (n_val >= 1) {
                const guard_id = tree.tokenSlice(k + 2);
                var matched = false;
                for (guard_names) |gn| {
                    if (std.mem.eql(u8, guard_id, gn)) { matched = true; break; }
                }
                if (matched and hasExitWithin(tags, k + 8, k + 11, t)) return true;
            }
        }

        // OR-branch early-exit: `if (A or GUARD == 0) return/break/continue`
        //   Dotted: `if (... or OUTER . INNER == 0) exit`
        //   Simple: `if (... or GUARD == 0) exit`
        // After the early-exit any path that reaches [t] has GUARD != 0.
        // Walk the condition of the if and look for `keyword_or GUARD == 0`
        // followed by `)` and then an exit.
        if (k + 2 < t and tags[k + 1] == .l_paren) {
            // Walk forward to find closing `)` at depth 0.
            // Start at k+2 (first token inside the paren) with depth=1.
            var depth2: u32 = 1;
            var j2: Ast.TokenIndex = k + 2;
            while (j2 < t and j2 < k + 80) : (j2 += 1) {
                if (tags[j2] == .l_paren) depth2 += 1 else if (tags[j2] == .r_paren) {
                    depth2 -= 1;
                    if (depth2 == 0) break;
                }
            }
            if (depth2 == 0 and hasExitWithin(tags, j2 + 1, j2 + 4, t)) {
                // Scan condition interior for `keyword_or GUARD == 0` patterns.
                var ci = k + 2;
                while (ci + 3 < j2) : (ci += 1) {
                    if (tags[ci] != .keyword_or) continue;
                    // Dotted: or OUTER . INNER == 0 ) — ci+6 must be j2
                    if (ci + 6 == j2 and
                        tags[ci + 1] == .identifier and
                        tags[ci + 2] == .period and
                        tags[ci + 3] == .identifier and
                        tags[ci + 4] == .equal_equal and
                        tags[ci + 5] == .number_literal and
                        std.mem.eql(u8, tree.tokenSlice(ci + 5), "0"))
                    {
                        const outer_id = tree.tokenSlice(ci + 1);
                        const inner_id = tree.tokenSlice(ci + 3);
                        var has_outer = false;
                        var has_inner = false;
                        for (guard_names) |gn| {
                            if (std.mem.eql(u8, outer_id, gn)) has_outer = true;
                            if (std.mem.eql(u8, inner_id, gn)) has_inner = true;
                        }
                        if (has_outer and has_inner) return true;
                    }
                    // Simple: or GUARD == 0 ) — ci+4 must be j2
                    if (ci + 4 == j2 and
                        tags[ci + 1] == .identifier and
                        tags[ci + 2] == .equal_equal and
                        tags[ci + 3] == .number_literal and
                        std.mem.eql(u8, tree.tokenSlice(ci + 3), "0"))
                    {
                        const guard_id = tree.tokenSlice(ci + 1);
                        for (guard_names) |gn| {
                            if (std.mem.eql(u8, guard_id, gn)) return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

/// True when `OUTER . INNER - 1` appears within 80 tokens before the `[` at
/// position `t` in a NON-subscript context (i.e. the `OUTER` token is NOT
/// immediately preceded by `[`).
///
/// Rationale: if a programmer writes `x = arr.field - 1` (arithmetic), they are
/// implicitly asserting `arr.field > 0` — otherwise the subtraction underflows.
/// A subsequent subscript `buf[arr.field - 1]` carries the same assumption, so
/// it is redundant to flag it separately.
///
/// Only applied to Form B (dotted OUTER.INNER) to avoid overly-broad suppression;
/// requires BOTH outer and inner names to match check_names (pair semantics).
fn hasPriorArithmeticGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 5) return false;
    const window: u32 = 80;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        if (k + 4 >= t) continue; // too close to the current subscript
        if (tags[k + 1] != .period) continue;
        if (tags[k + 2] != .identifier) continue;
        if (tags[k + 3] != .minus) continue;
        if (tags[k + 4] != .number_literal) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k + 4), "1")) continue;
        // Skip if this is itself a subscript expression (preceded by `[`).
        if (k > 0 and tags[k - 1] == .l_bracket) continue;
        // Require both names to match (pair semantics prevents false suppression).
        const outer = tree.tokenSlice(k);
        const inner = tree.tokenSlice(k + 2);
        var has_outer = false;
        var has_inner = false;
        for (guard_names) |gn| {
            if (std.mem.eql(u8, outer, gn)) has_outer = true;
            if (std.mem.eql(u8, inner, gn)) has_inner = true;
        }
        if (has_outer and has_inner) return true;
    }
    return false;
}

/// True if `return`, `continue`, or `break` appears in [from, min(to, bound)).
/// All three exit the current execution path, so when any follows `if (x == 0)`,
/// the code after the if is only reached when `x != 0`.
fn hasExitWithin(tags: []const std.zig.Token.Tag, from: Ast.TokenIndex, to: Ast.TokenIndex, bound: Ast.TokenIndex) bool {
    const end = @min(to, bound);
    var i = from;
    while (i < end) : (i += 1) {
        switch (tags[i]) {
            .keyword_return, .keyword_continue, .keyword_break => return true,
            else => {},
        }
    }
    return false;
}

/// True when `IDENT [ 0 ]` appears within 40 tokens before `t` and IDENT
/// matches one of `guard_names`.  Accessing index 0 of a slice/array asserts
/// it is non-empty, so `slice[slice.len - 1]` later in the same expression
/// or statement is safe.
fn hasZeroAccessGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 4) return false;
    const window: u32 = 40;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        if (k + 3 >= t) continue;
        if (tags[k + 1] != .l_bracket) continue;
        if (tags[k + 2] != .number_literal or !std.mem.eql(u8, tree.tokenSlice(k + 2), "0")) continue;
        if (tags[k + 3] != .r_bracket) continue;
        const id = tree.tokenSlice(k);
        for (guard_names) |gn| {
            if (std.mem.eql(u8, id, gn)) return true;
        }
    }
    return false;
}

/// True when `IDENT += 1` appears within 35 tokens before `t`.  After
/// `x += 1`, x ≥ 1, so `arr[x - 1]` is in bounds.
fn hasIncrementGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 3) return false;
    const window: u32 = 35;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        if (k + 2 >= t) continue;
        if (tags[k + 1] != .plus_equal) continue;
        if (tags[k + 2] != .number_literal or !std.mem.eql(u8, tree.tokenSlice(k + 2), "1")) continue;
        const id = tree.tokenSlice(k);
        for (guard_names) |gn| {
            if (std.mem.eql(u8, id, gn)) return true;
        }
    }
    return false;
}

/// True when `IDENT ... = 1` (initialized to 1) appears within 50 tokens
/// before `t`.  Looks forward up to 5 tokens from the identifier for `= 1`,
/// skipping an optional `: Type` annotation.  `var x: T = 1` means x starts
/// at 1, making `arr[x - 1]` safe on its first use.
fn hasInitToOneGuard(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    t: Ast.TokenIndex,
    guard_names: []const []const u8,
) bool {
    if (t < 5) return false;
    const window: u32 = 50;
    const start: Ast.TokenIndex = if (t >= window) t - window else 0;
    var k: Ast.TokenIndex = t;
    while (k > start) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        const id = tree.tokenSlice(k);
        var matched = false;
        for (guard_names) |gn| {
            if (std.mem.eql(u8, id, gn)) { matched = true; break; }
        }
        if (!matched) continue;
        // Only match LOCAL variable declarations (preceded by `const` or `var`).
        // Struct field defaults (`field: type = 1,`) and function parameters
        // must not trigger this guard — the default does not prove the value is
        // always 1 at runtime (it can be changed after construction).
        if (k == 0 or (tags[k - 1] != .keyword_const and tags[k - 1] != .keyword_var)) continue;
        // Scan forward up to 5 tokens for `equal number_literal("1")`.
        var j = k + 1;
        while (j < t and j <= k + 5) : (j += 1) {
            if (tags[j] == .equal) {
                if (j + 1 < t and
                    tags[j + 1] == .number_literal and
                    std.mem.eql(u8, tree.tokenSlice(j + 1), "1"))
                    return true;
                break;
            }
        }
    }
    return false;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    lb_tok: Ast.TokenIndex,
    idx_name: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`[{s} - 1]` — if `{s}` is `usize` (or any unsigned type) and equals `0`, the subtraction wraps to `maxInt(usize)`, producing an OOB panic (Debug/Safe) or silent arbitrary-memory read (ReleaseFast); add a `{s} > 0` (or `{s} != 0`) guard before this expression",
        .{ idx_name, idx_name, idx_name, idx_name },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, lb_tok),
        .end = Pos.fromTokenEnd(tree, lb_tok + 4),
        .message = msg,
    });
}

fn reportC(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    lb_tok: Ast.TokenIndex,
    recv: []const u8,
    field: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`[{s}.{s}.len - 1]` — if `{s}.{s}.len` is `0`, the subtraction wraps to `maxInt(usize)`, producing an OOB panic (Debug/Safe) or silent arbitrary-memory read (ReleaseFast); add a `{s}.{s}.len > 0` guard before this expression",
        .{ recv, field, recv, field, recv, field },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, lb_tok),
        .end = Pos.fromTokenEnd(tree, lb_tok + 8),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: basic fires" {
    try testing.expectFires(check, R,
        \\fn prev(items: []const u8, idx: usize) u8 {
        \\    return items[idx - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: field minus one fires" {
    try testing.expectFires(check, R,
        \\const Self = struct { current: usize, items: []const u8 };
        \\fn prev(self: Self) u8 {
        \\    return self.items[self.current - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: idx - 2 does not fire" {
    try testing.expectNoFire(check,
        \\fn f(items: []const u8, idx: usize) u8 {
        \\    return items[idx - 2];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: idx + 1 does not fire" {
    try testing.expectNoFire(check,
        \\fn f(items: []const u8, idx: usize) u8 {
        \\    return items[idx + 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: plain index does not fire" {
    try testing.expectNoFire(check,
        \\fn f(items: []const u8, idx: usize) u8 {
        \\    return items[idx];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: recv.field.len - 1 fires (Form C)" {
    try testing.expectFires(check, R,
        \\const Self = struct { args: []const u8 };
        \\fn deinit(self: *Self) void {
        \\    _ = self.args[self.args.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: recv.field.len - 2 does not fire" {
    try testing.expectNoFire(check,
        \\const Self = struct { args: []const u8 };
        \\fn f(self: *Self) void {
        \\    _ = self.args[self.args.len - 2];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A suppressed by and-guard" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, x: usize) u8 {
        \\    return if (x > 0 and buf[x - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A suppressed by != 0 and-guard" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, x: usize) u8 {
        \\    return if (x != 0 and buf[x - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A fires when guard uses different ident" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, x: usize, y: usize) u8 {
        \\    return if (y > 0 and buf[x - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form B suppressed by and-guard on outer ident" {
    try testing.expectNoFire(check,
        \\fn f(items: []const u8, s: anytype) bool {
        \\    return s.len > 0 and items[s.len - 1] == 0;
        \\}
        \\
    );
}

// ── If-body guard tests ────────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: Form A suppressed by if-body guard (simple)" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, x: usize) void {
        \\    if (x > 0) assert(buf[x - 1] == 0);
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A suppressed by if-body guard (!= 0)" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, x: usize) void {
        \\    if (x != 0) doSomething(buf[x - 1]);
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A fires when guard uses different ident (if-body)" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, x: usize, y: usize) void {
        \\    if (y > 0) _ = buf[x - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A fires when if guard is followed by semicolon" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, x: usize) void {
        \\    if (x > 0) doSomething();
        \\    _ = buf[x - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form A suppressed inside multi-statement block" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, x: usize) void {
        \\    if (x > 0) {
        \\        doSomething();
        \\        _ = buf[x - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form B suppressed by if-body guard (dotted)" {
    try testing.expectNoFire(check,
        \\fn f(arr: []const u8, s: anytype) void {
        \\    if (s.len > 0) assert(arr[s.len - 1] == 0);
        \\}
        \\
    );
}

// ── Assert guard tests ─────────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: Form A suppressed by assert guard (simple)" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, n: usize) u8 {
        \\    assert(n > 0);
        \\    return buf[n - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form B suppressed by assert guard (dotted)" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, s: anytype) u8 {
        \\    assert(s.len > 0);
        \\    return buf[s.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: assert guard with != 0 suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, n: usize) u8 {
        \\    assert(n != 0);
        \\    return buf[n - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: assert guard on different ident still fires" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, n: usize, m: usize) u8 {
        \\    assert(m > 0);
        \\    return buf[n - 1];
        \\}
        \\
    );
}

// ── Early-return guard tests ───────────────────────────────────────────────

test "index-minus-one-without-zero-guard: Form A suppressed by early-return guard" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, n: usize) !u8 {
        \\    if (n == 0) return error.Empty;
        \\    return buf[n - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: Form B suppressed by early-return guard (dotted)" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, s: anytype) !u8 {
        \\    if (s.len == 0) return error.Empty;
        \\    return buf[s.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: early-return guard on different ident still fires" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, n: usize, m: usize) !u8 {
        \\    if (m == 0) return error.Empty;
        \\    return buf[n - 1];
        \\}
        \\
    );
}

// ── Comptime context tests ─────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: comptime assert suppressed" {
    try testing.expectNoFire(check,
        \\fn f(comptime fmt: []const u8) void {
        \\    comptime assert(fmt[fmt.len - 1] == '\n');
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: runtime access still fires" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, n: usize) u8 {
        \\    return buf[n - 1];
        \\}
        \\
    );
}
// ── Else-body guard tests ──────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: else-body guarded by == 0 condition" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, n: usize) u8 {
        \\    return if (n == 0) 0 else buf[n - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: else-block guarded by == 0 condition" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, idx: usize) u8 {
        \\    if (idx == 0) {
        \\        return 0;
        \\    } else {
        \\        return buf[idx - 1];
        \\    }
        \\}
        \\
    );
}

// ── Compound assert guard tests ────────────────────────────────────────────

test "index-minus-one-without-zero-guard: compound assert (and) suppresses" {
    try testing.expectNoFire(check,
        \\fn f(a: []const u8, b: []const u8) u8 {
        \\    assert(a.len > 0 and b.len > 0);
        \\    return b[b.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: OR-short-circuit assert suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, n: usize) bool {
        \\    assert(n == 0 or buf[n - 1] == 0);
        \\    return true;
        \\}
        \\
    );
}

// ── Continue / break guard tests ───────────────────────────────────────────

test "index-minus-one-without-zero-guard: continue guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8) void {
        \\    for (0..buf.len) |i| {
        \\        if (i == 0) continue;
        \\        _ = buf[i - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: break guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, i: usize) void {
        \\    if (i == 0) break;
        \\    _ = buf[i - 1];
        \\}
        \\
    );
}

// ── Zero-access guard tests ────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: prior [0] access suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8) u8 {
        \\    _ = buf[0];
        \\    return buf[buf.len - 1];
        \\}
        \\
    );
}

// ── Increment guard tests ──────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: += 1 before subscript suppresses" {
    try testing.expectNoFire(check,
        \\fn f(arr: []u8, count: *usize) u8 {
        \\    count.* += 1;
        \\    return arr[count.* - 1];
        \\}
        \\
    );
}

// ── Init-to-one guard tests ────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: var x = 1 suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8) void {
        \\    var count: usize = 1;
        \\    _ = buf[count - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: loop var starting at 1 suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8) void {
        \\    var i: usize = 1;
        \\    while (i < buf.len) : (i += 1) {
        \\        _ = buf[i - 1];
        \\    }
        \\}
        \\
    );
}

// ── Constants guard tests ──────────────────────────────────────────────────

test "index-minus-one-without-zero-guard: constants.X - 1 does not fire" {
    try testing.expectNoFire(check,
        \\fn f(levels: anytype) void {
        \\    _ = levels[constants.max_level - 1];
        \\}
        \\
    );
}

// ── For-range (1..N) and literal-array guard tests ────────────────────────

test "index-minus-one-without-zero-guard: for (1..N) capture suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8) void {
        \\    for (1..buf.len) |i| {
        \\        _ = buf[i - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: for (2..N) capture suppresses" {
    try testing.expectNoFire(check,
        \\fn f(arr: []const u8) void {
        \\    for (2..arr.len) |i| {
        \\        _ = arr[i - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: for (0..N) capture still fires" {
    try testing.expectFires(check, R,
        \\fn f(arr: []const u8) void {
        \\    for (0..arr.len) |i| {
        \\        _ = arr[i - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: inline for over all-positive literals suppresses" {
    try testing.expectNoFire(check,
        \\fn f(blocks: []u8) void {
        \\    inline for ([_]usize{ 7, 6, 5, 4, 3, 2, 1 }) |i| {
        \\        blocks[i] = blocks[i - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: for over array containing 0 still fires" {
    try testing.expectFires(check, R,
        \\fn f(blocks: []u8) void {
        \\    for ([_]usize{ 3, 2, 1, 0 }) |i| {
        \\        blocks[i] = blocks[i - 1];
        \\    }
        \\}
        \\
    );
}

// ── Cross-pass 1: slice-to-len-minus-one guard tests ──────────────────────

test "index-minus-one-without-zero-guard: for input entries[0..entries.len-1] suppresses" {
    try testing.expectNoFire(check,
        \\fn f(entries: []const u8) void {
        \\    for (entries[0 .. entries.len - 1], entries[1..]) |a, b| {
        \\        _ = a;
        \\        _ = b;
        \\    }
        \\    _ = entries[entries.len - 1];
        \\}
        \\
    );
}

// ── Cross-pass 2: function-wide dotted assert tests ────────────────────────

test "index-minus-one-without-zero-guard: assert(x.len > 0) anywhere in body suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8) u8 {
        \\    assert(buf.len > 0);
        \\    const n = buf.len;
        \\    const x = n * 2;
        \\    _ = x;
        \\    return buf[buf.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: assert on different ident does not suppress" {
    try testing.expectFires(check, R,
        \\fn f(a: []const u8, b: []const u8) u8 {
        \\    assert(a.len > 0);
        \\    return b[b.len - 1];
        \\}
        \\
    );
}

// ── Cross-pass 3: callee postcondition tests ───────────────────────────────

test "index-minus-one-without-zero-guard: callee postcondition assert(X.F.len>=1) suppresses" {
    try testing.expectNoFire(check,
        \\fn getSlice(msg: []const u8) Wrapper {
        \\    return .{ .slice = msg };
        \\}
        \\fn verify(msg: []const u8) void {
        \\    const h = getSlice(msg);
        \\    assert(h.slice.len >= 1);
        \\}
        \\fn use(msg: []const u8) u8 {
        \\    const h = getSlice(msg);
        \\    return h.slice[h.slice.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: callee postcondition does not suppress different local" {
    try testing.expectFires(check, R,
        \\fn getSlice(msg: []const u8) Wrapper {
        \\    return .{ .slice = msg };
        \\}
        \\fn verify(msg: []const u8) void {
        \\    const h = getSlice(msg);
        \\    assert(h.slice.len >= 1);
        \\}
        \\fn use(msg: []const u8, other: []const u8) u8 {
        \\    _ = getSlice(msg);
        \\    return other[other.len - 1];
        \\}
        \\
    );
}

// ── Optional payload (getLastOrNull) guard tests ───────────────────────────

test "index-minus-one-without-zero-guard: getLastOrNull payload suppresses" {
    try testing.expectNoFire(check,
        \\fn f(result: anytype) void {
        \\    if (result.getLastOrNull()) |_| {
        \\        _ = result.items[result.items.len - 1];
        \\    }
        \\}
        \\
    );
}

// ── Prior arithmetic guard tests ───────────────────────────────────────────

test "index-minus-one-without-zero-guard: prior non-subscript OUTER.INNER-1 suppresses" {
    try testing.expectNoFire(check,
        \\fn f(s: anytype, arr: []u8) void {
        \\    arr[0] = @intCast(s.len - 1); // arithmetic: implicitly assumes s.len > 0
        \\    _ = arr[s.len - 1];            // subscript: same assumption, suppressed
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: prior arithmetic on different pair still fires" {
    try testing.expectFires(check, R,
        \\fn f(a: anytype, b: anytype, arr: []u8) void {
        \\    arr[0] = @intCast(a.len - 1); // guard on a.len, not b.len
        \\    _ = arr[b.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: getLastOrNull different base still fires" {
    try testing.expectFires(check, R,
        \\fn f(a: anytype, b: []const u8) void {
        \\    if (a.getLastOrNull()) |_| {
        \\        _ = b[b.len - 1];
        \\    }
        \\}
        \\
    );
}

// ── Cross-pass 4: alloc-plus-N tests ──────────────────────────────────────

test "index-minus-one-without-zero-guard: alloc with +1 size suppresses" {
    try testing.expectNoFire(check,
        \\fn f(gpa: anytype, src: []const u8) void {
        \\    const buf = try gpa.alloc(u8, src.len + 1);
        \\    _ = buf[buf.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: alloc with +0 size still fires" {
    try testing.expectFires(check, R,
        \\fn f(gpa: anytype, src: []const u8) void {
        \\    const buf = try gpa.alloc(u8, src.len + 0);
        \\    _ = buf[buf.len - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: alloc different local still fires" {
    try testing.expectFires(check, R,
        \\fn f(gpa: anytype, src: []const u8, other: []const u8) void {
        \\    _ = try gpa.alloc(u8, src.len + 1);
        \\    _ = other[other.len - 1];
        \\}
        \\
    );
}

// ── Cross-variable >= N+M guard tests (#7) ────────────────────────────────

test "index-minus-one-without-zero-guard: x >= y+2 and-guard suppresses" {
    // span_end >= span_start + 2 guarantees span_end >= 2 > 0.
    try testing.expectNoFire(check,
        \\fn f(src: []const u8, span_end: usize, span_start: usize) bool {
        \\    if (span_end >= span_start + 2 and src[span_end - 1] == '{') return true;
        \\    return false;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: x >= y+1 and-guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, end: usize, start: usize) u8 {
        \\    return if (end >= start + 1 and buf[end - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: x >= y+2 in if-body suppresses" {
    try testing.expectNoFire(check,
        \\fn f(src: []const u8, end: usize, start: usize) u8 {
        \\    if (end >= start + 2) return src[end - 1];
        \\    return 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: x >= y+0 does not suppress" {
    // N == 0 does not imply x >= 1.
    try testing.expectFires(check, R,
        \\fn f(src: []const u8, end: usize, start: usize) u8 {
        \\    return if (end >= start + 0 and src[end - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: different ident >= y+2 still fires" {
    try testing.expectFires(check, R,
        \\fn f(src: []const u8, end: usize, start: usize, other: usize) u8 {
        \\    return if (other >= start + 2 and src[end - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

// ── Cross-variable early-exit guard tests (#7b) ───────────────────────────

test "index-minus-one-without-zero-guard: if (x < y+N) return suppresses" {
    // After `if (end < start + 2) return null`, end >= start+2 >= 2 > 0.
    try testing.expectNoFire(check,
        \\fn f(tags: []const u8, end: usize, start: usize) ?u8 {
        \\    if (end < start + 2) return null;
        \\    return tags[end - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: if (x < y+1) return suppresses" {
    try testing.expectNoFire(check,
        \\fn f(tags: []const u8, rparen: usize, t: usize) ?u8 {
        \\    if (rparen < t + 1) return null;
        \\    return tags[rparen - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: if (x < y+0) return does not suppress" {
    // N == 0 does not guarantee x >= 1.
    try testing.expectFires(check, R,
        \\fn f(tags: []const u8, end: usize, start: usize) ?u8 {
        \\    if (end < start + 0) return null;
        \\    return tags[end - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: different ident in if-x-lt-y+N still fires" {
    // `other < start + 2` guards `other`, not `end`.
    try testing.expectFires(check, R,
        \\fn f(tags: []const u8, end: usize, start: usize, other: usize) ?u8 {
        \\    if (other < start + 2) return null;
        \\    return tags[end - 1];
        \\}
        \\
    );
}

// ── Compound or early-return guard tests (#8) ─────────────────────────────

test "index-minus-one-without-zero-guard: if (e <= s or ...) return suppresses" {
    // e <= s catches e == 0 (usize), so after the return e >= 1.
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, e: usize, s: usize, len: usize) !u8 {
        \\    if (e <= s or e > len) return error.OutOfRange;
        \\    return buf[e - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: if (e <= s) return suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, e: usize, s: usize) !u8 {
        \\    if (e <= s) return error.Empty;
        \\    return buf[e - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: compound or-return on different ident still fires" {
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, e: usize, s: usize, other: usize) !u8 {
        \\    if (other <= s or other > buf.len) return error.OutOfRange;
        \\    return buf[e - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: if (A or p.tok_i == 0) return suppresses dotted" {
    // `p.tok_i == 0` is the RHS of OR early-return; after return tok_i != 0.
    try testing.expectNoFire(check,
        \\fn emitJsxGap(p: *Parser, last_child_was_text: bool, starts: []u32, lens: []u16) !void {
        \\    if (last_child_was_text or p.tok_i == 0) return;
        \\    const prev_end = starts[p.tok_i - 1] + lens[p.tok_i - 1];
        \\    _ = prev_end;
        \\}
        \\const Parser = struct { tok_i: usize };
        \\
    );
}

test "index-minus-one-without-zero-guard: if (A or x == 0) return suppresses simple" {
    try testing.expectNoFire(check,
        \\fn f(buf: []const u8, flag: bool, x: usize) !u8 {
        \\    if (flag or x == 0) return error.Empty;
        \\    return buf[x - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: if (A or other == 0) return still fires for different ident" {
    // `other == 0` guards `other`, not `x`.
    try testing.expectFires(check, R,
        \\fn f(buf: []const u8, flag: bool, x: usize, other: usize) !u8 {
        \\    if (flag or other == 0) return error.Empty;
        \\    return buf[x - 1];
        \\}
        \\
    );
}

// ── Derived-variable guard tests (#9) — value-range DiffAlias + lit>=2 ───────
// These exercise the full chain: `const n = end - 0 (or .len)` +
// `if (n < 2) return` → n >= 2 in fall-through → end >= 2 >= 1 → no fire.
// The real-world case `range.end - range.start` (identifier subtrahend) only
// fires in production where ZLS can confirm `range.start` is unsigned.

test "index-minus-one-without-zero-guard: diff-alias n=end-0 + if (n<2) return suppresses" {
    try testing.expectNoFire(check,
        \\fn f(end: usize, buf: []const u8) u8 {
        \\    const n = end - 0;
        \\    if (n < 2) return 0;
        \\    return buf[end - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: diff-alias n=end-other.len + if (n<2) return suppresses" {
    try testing.expectNoFire(check,
        \\fn f(end: usize, other: []const u8, buf: []const u8) u8 {
        \\    const n = end - other.len;
        \\    if (n < 2) return 0;
        \\    return buf[end - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: if (n < 2) return without diff-alias fires" {
    // Guard on unrelated `n` does not suppress `end - 1`.
    try testing.expectFires(check, R,
        \\fn f(end: usize, n: usize, buf: []const u8) u8 {
        \\    if (n < 2) return 0;
        \\    return buf[end - 1];
        \\}
        \\
    );
}

// ── Or-guard (same-expression short-circuit) tests ────────────────────────

test "index-minus-one-without-zero-guard: same-expression i==0 or-guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(src: []const u8, i: usize) bool {
        \\    if (i == 0 or src[i - 1] == '\n') return true;
        \\    return false;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: or-guard with != still fires (wrong sense)" {
    try testing.expectFires(check, R,
        \\fn f(src: []const u8, i: usize) bool {
        \\    if (i != 0 or src[i - 1] == '\n') return true;
        \\    return false;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: or-guard on different ident still fires" {
    try testing.expectFires(check, R,
        \\fn f(src: []const u8, i: usize, j: usize) bool {
        \\    if (j == 0 or src[i - 1] == '\n') return true;
        \\    return false;
        \\}
        \\
    );
}

// ── Monotone-positive field tests ──────────────────────────────────────────

test "index-minus-one-without-zero-guard: monotone @max field suppresses" {
    try testing.expectNoFire(check,
        \\const S = struct {
        \\    limit: usize = 1,
        \\};
        \\fn upgrade(s: *S) void {
        \\    s.limit = @max(s.limit, 2);
        \\}
        \\fn use(arr: []const u8, s: S) u8 {
        \\    return arr[s.limit - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: non-monotone field still fires" {
    try testing.expectFires(check, R,
        \\const S = struct {
        \\    limit: usize = 1,
        \\};
        \\fn downgrade(s: *S) void {
        \\    s.limit = 0; // non-@max assignment disqualifies
        \\}
        \\fn use(arr: []const u8, s: S) u8 {
        \\    return arr[s.limit - 1];
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: >= 1 and-guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(s: []const u8, pad: u8) bool {
        \\    return s.len >= 1 and s[s.len - 1] == pad;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: > 1 and-guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(s: []const u8) u8 {
        \\    if (s.len > 1 and s[s.len - 1] == 0) return 1;
        \\    return 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: len < 2 or-guard suppresses" {
    try testing.expectNoFire(check,
        \\fn f(raw: []const u8) bool {
        \\    if (raw.len < 2 or raw[raw.len - 1] != 'n') return false;
        \\    return true;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: >= 0 and-guard does not suppress" {
    try testing.expectFires(check, R,
        \\fn f(n: usize, buf: []u8) u8 {
        \\    return if (n >= 0 and buf[n - 1] == 0) 1 else 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: while > 0 body suppresses" {
    try testing.expectNoFire(check,
        \\fn f(buf: []i32, n: usize) void {
        \\    var i = n;
        \\    while (i > 0) : (i -= 1) {
        \\        _ = buf[i - 1];
        \\    }
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: while items.len > 0 body suppresses" {
    try testing.expectNoFire(check,
        \\fn f(stack: *std.ArrayList(u32)) u32 {
        \\    while (stack.items.len > 0) {
        \\        return stack.items[stack.items.len - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    );
}

test "index-minus-one-without-zero-guard: while cond without zero-guard still fires" {
    try testing.expectFires(check, R,
        \\fn f(buf: []u8, n: usize) u8 {
        \\    // while condition doesn't constrain n > 0
        \\    var done = false;
        \\    while (!done) { done = true; }
        \\    return buf[n - 1];
        \\}
        \\
    );
}
