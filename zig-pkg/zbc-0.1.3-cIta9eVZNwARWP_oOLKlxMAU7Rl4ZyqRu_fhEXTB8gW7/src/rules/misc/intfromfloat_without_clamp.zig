//! Detects `@intFromFloat(<expr>)` where the float argument is not
//! guarded by a clamp/min/max inside the call's argument expression.
//!
//! `@intFromFloat` panics in Debug/Safe when the float value is outside
//! the target integer's range, is NaN, or is ±Inf.  In ReleaseFast it
//! produces undefined behaviour.  Timer values, peer-advertised timeouts,
//! and GC-scheduler floats received from the JS engine can be huge
//! (or infinite) and must be clamped before conversion.
//!
//! Pattern (fires):
//!   const sec: i64 = @intFromFloat(seconds);        // seconds may be +Inf
//!   interval.sec += @intFromFloat(modf.ipart);       // modf.ipart from JS timer
//!
//! Safe forms (suppressed):
//!   @intFromFloat(@min(seconds, @as(f64, std.math.maxInt(i32))))
//!   @intFromFloat(@max(@min(x, max_f), min_f))
//!   @intFromFloat(@round(x))   -- @floor / @ceil / @trunc are also accepted
//!
//! Real-world shape: oven-sh/bun#28364 (Timer: modf.ipart ± Inf panic),
//!                   oven-sh/bun#29328 (GC scheduler float out of i64 range).
//!
//! Detection (Tier 1, token walk):
//!   1. Scan for `.builtin` token with slice "@intFromFloat".
//!   2. The next token must be `.l_paren`.
//!   3. Scan the argument expression (up to the matching `r_paren`)
//!      for a `.builtin` token whose slice is "@min", "@max", "@round",
//!      "@floor", "@ceil", "@trunc".  If found, suppress.
//!   4. Also suppress if `std.math.clamp` appears as an identifier
//!      sequence in the argument.
//!   5. Fire at the `@intFromFloat` builtin token.

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const tokens = @import("../../ast/tokens.zig");
const testing = @import("../../testing.zig");

const matchParen = tokens.matchParen;
const skipNestedFn = tokens.skipNestedFn;

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "intfromfloat-without-clamp";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .intfromfloat_without_clamp)) return;
    _ = cache;
    try tokens.forEachFnBody(gpa, tree, problems, checkBody);
}

fn checkBody(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body: Ast.Node.Index,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    const tags = tree.tokens.items(.tag);
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);

    var t: Ast.TokenIndex = first;
    while (t + 1 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }

        if (tags[t] != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t), "@intFromFloat")) continue;
        if (t + 1 > last or tags[t + 1] != .l_paren) continue;

        // Find the matching close-paren for the @intFromFloat(...) call.
        const arg_open = t + 1;
        const arg_close = matchParen(tags, arg_open, last) orelse last;

        // Suppress if the argument contains a clamp/min/max/rounding builtin.
        if (argHasClampGuard(tree, tags, arg_open, arg_close)) continue;
        // For single-identifier arguments, also check whether the variable's
        // own declaration has a guard builtin in its RHS.  This catches
        // `const cell_width = @round(face_width); … @intFromFloat(cell_width)`.
        if (arg_close == arg_open + 2 and tags[arg_open + 1] == .identifier) {
            const var_name = tree.tokenSlice(arg_open + 1);
            if (declHasGuard(tree, tags, t, var_name)) continue;
            // Also suppress when the surrounding code contains an AND-range guard:
            // `VAR >= LOW … and … VAR < HIGH` (or the symmetric form).  Both a
            // lower bound (`>=` / `>`) and an upper bound (`<` / `<=`) with `and`
            // connecting them prove the value is finite and in-range — NaN fails
            // every IEEE 754 comparison, so it can't pass both sides of an `and`.
            if (hasAndRangeGuard(tree, tags, t, var_name)) continue;
            // Suppress when `@floor(VAR)` or `@trunc(VAR)` appears in a runtime
            // computation (not inside assert) within 200 tokens before.  The
            // `x - @floor(x) == 0` (is-integer) check excludes NaN and ±Inf:
            //   @floor(NaN)=NaN, NaN-NaN=NaN, NaN==0 → false → not integer
            //   @floor(±Inf)=±Inf, ±Inf-±Inf=NaN, NaN==0 → false → not integer
            if (hasFloorRuntimeCheck(tree, tags, t, var_name)) continue;
        }

        try report(gpa, problems, tree, t);
    }
}

/// Returns true iff the token range (arg_open..arg_close) contains a
/// builtin that guards against out-of-range float values:
///   @min, @max, @round, @floor, @ceil, @trunc
/// OR the identifier sequence `clamp` (for std.math.clamp).
/// OR `@floatFromInt` — the float was derived from an integer, so it cannot
/// be NaN or ±Inf; any arithmetic on it stays finite as long as operands are
/// finite (load factors, scale factors from config are always finite).
/// OR `@as(f32/f64, …)` — the argument was explicitly cast to a known float
/// type from a finite expression, bounding NaN/Inf risk.
fn argHasClampGuard(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    arg_open: Ast.TokenIndex,
    arg_close: Ast.TokenIndex,
) bool {
    if (arg_open >= arg_close) return false;
    var t: Ast.TokenIndex = arg_open + 1;
    while (t < arg_close) : (t += 1) {
        if (tags[t] == .builtin) {
            const s = tree.tokenSlice(t);
            if (std.mem.eql(u8, s, "@min") or
                std.mem.eql(u8, s, "@max") or
                std.mem.eql(u8, s, "@round") or
                std.mem.eql(u8, s, "@floor") or
                std.mem.eql(u8, s, "@ceil") or
                std.mem.eql(u8, s, "@trunc") or
                // Integer-origin: @floatFromInt always produces a finite float.
                std.mem.eql(u8, s, "@floatFromInt")) return true;
        }
        if (tags[t] == .identifier) {
            const s = tree.tokenSlice(t);
            if (std.mem.eql(u8, s, "clamp") or
                // std.math equivalents of the builtin rounding functions.
                std.mem.eql(u8, s, "floor") or
                std.mem.eql(u8, s, "ceil") or
                std.mem.eql(u8, s, "round") or
                std.mem.eql(u8, s, "trunc") or
                // std.math.lossyCast is an explicit safe conversion.
                std.mem.eql(u8, s, "lossyCast")) return true;
        }
        // A float literal in the argument (e.g. `v / 100.0 * dim`) suggests
        // the computation involves bounded scaling — suppress.
        if (tags[t] == .number_literal and
            std.mem.indexOf(u8, tree.tokenSlice(t), ".") != null) return true;
    }
    return false;
}

/// For a single-identifier argument `@intFromFloat(VAR)`, scan backward up to
/// 500 tokens to find `const/var VAR = <rhs>` and check whether the RHS
/// contains a guard builtin.  Catches patterns like:
///   const cell_width = @round(face_width);
///   …
///   .cell_width = @intFromFloat(cell_width),
fn declHasGuard(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    anchor: Ast.TokenIndex,
    var_name: []const u8,
) bool {
    const back: Ast.TokenIndex = 500;
    const start: Ast.TokenIndex = if (anchor >= back) anchor - back else 0;
    var k = anchor;
    while (k > start + 1) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k), var_name)) continue;
        if (tags[k - 1] != .keyword_const and tags[k - 1] != .keyword_var) continue;
        // Found declaration; scan RHS for guard builtins (up to semicolon).
        var j = k + 1;
        const rhs_end = @min(k + 100, anchor);
        while (j < rhs_end) : (j += 1) {
            if (tags[j] == .semicolon) break;
            if (tags[j] == .builtin) {
                const s = tree.tokenSlice(j);
                if (std.mem.eql(u8, s, "@min") or std.mem.eql(u8, s, "@max") or
                    std.mem.eql(u8, s, "@round") or std.mem.eql(u8, s, "@floor") or
                    std.mem.eql(u8, s, "@ceil") or std.mem.eql(u8, s, "@trunc") or
                    std.mem.eql(u8, s, "@floatFromInt")) return true;
            }
            if (tags[j] == .identifier) {
                const s = tree.tokenSlice(j);
                if (std.mem.eql(u8, s, "floor") or std.mem.eql(u8, s, "ceil") or
                    std.mem.eql(u8, s, "round") or std.mem.eql(u8, s, "trunc") or
                    std.mem.eql(u8, s, "clamp") or std.mem.eql(u8, s, "lossyCast")) return true;
            }
        }
    }
    return false;
}

/// Returns true iff `@floor(VAR_NAME)` or `@trunc(VAR_NAME)` appears in a
/// runtime computation (not inside `assert(...)`) within 200 tokens before
/// `@intFromFloat(VAR_NAME)`.  This guards the "is-integer check" pattern:
///   const floored = @floor(x);
///   const is_integer = (x - floored) == 0;
///   if (x < MAX and is_integer) { @intFromFloat(x) }
/// The is-integer check excludes NaN and ±Inf because `@floor(NaN)` = NaN,
/// `NaN - NaN` = NaN, and `NaN == 0` = false; and `@floor(±Inf)` = ±Inf,
/// `±Inf - ±Inf` = NaN.  Only runtime @floor (not assert-guarded) counts.
fn hasFloorRuntimeCheck(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    anchor: Ast.TokenIndex,
    var_name: []const u8,
) bool {
    const back: Ast.TokenIndex = 200;
    const start: Ast.TokenIndex = if (anchor >= back) anchor - back else 0;

    var k = start;
    while (k + 3 < anchor) : (k += 1) {
        if (tags[k] != .builtin) continue;
        const s = tree.tokenSlice(k);
        if (!std.mem.eql(u8, s, "@floor") and !std.mem.eql(u8, s, "@trunc")) continue;
        if (tags[k + 1] != .l_paren) continue;
        if (tags[k + 2] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k + 2), var_name)) continue;
        if (tags[k + 3] != .r_paren) continue;

        // Reject if this @floor(VAR) is the direct argument to assert(...):
        //   assert(@floor(x) == x) — only a debug check, not runtime.
        if (k >= 2 and
            tags[k - 1] == .l_paren and
            tags[k - 2] == .identifier and
            std.mem.eql(u8, tree.tokenSlice(k - 2), "assert"))
            continue;

        return true;
    }
    return false;
}

/// Returns true iff the 200-token window before `anchor` contains BOTH:
///   - `VAR < x` or `VAR <= x` (upper bound — excludes +Inf and NaN), AND
///   - `VAR > y` or `VAR >= y` (lower bound — excludes -Inf and NaN),
/// with `and` (not `or`) between the two comparison sites.
///
/// The AND requirement distinguishes a paired range check like
/// `value >= -2^31 and value < 2^31` (excludes NaN via short-circuit)
/// from an OR-based exit guard like `value < 0 or value > MAX` which does
/// NOT exclude NaN (`NaN < 0` = false AND `NaN > MAX` = false → NaN passes).
fn hasAndRangeGuard(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    anchor: Ast.TokenIndex,
    var_name: []const u8,
) bool {
    const back: Ast.TokenIndex = 200;
    const start: Ast.TokenIndex = if (anchor >= back) anchor - back else 0;

    var upper_pos: ?Ast.TokenIndex = null; // VAR < x or VAR <= x
    var lower_pos: ?Ast.TokenIndex = null; // VAR > y or VAR >= y

    var k: Ast.TokenIndex = start;
    while (k + 1 < anchor) : (k += 1) {
        if (tags[k] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k), var_name)) continue;
        const op = tags[k + 1];
        if ((op == .angle_bracket_left or op == .angle_bracket_left_equal) and upper_pos == null)
            upper_pos = k;
        if ((op == .angle_bracket_right or op == .angle_bracket_right_equal) and lower_pos == null)
            lower_pos = k;
    }

    if (upper_pos == null or lower_pos == null) return false;

    // Scan between the two comparison sites for `and` (good) or `or` (bad).
    const lo = @min(upper_pos.?, lower_pos.?) + 2;
    const hi = @max(upper_pos.?, lower_pos.?);
    if (lo >= hi) return false;

    var has_and = false;
    k = lo;
    while (k < hi) : (k += 1) {
        if (tags[k] == .keyword_and) has_and = true;
        if (tags[k] == .keyword_or) return false; // OR-based guard doesn't exclude NaN
    }
    return has_and;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    builtin_tok: Ast.TokenIndex,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`@intFromFloat` without a preceding clamp/min/max guard — if the float argument is ±Inf, NaN, or outside the target integer's range, this panics in Debug/Safe and produces undefined behaviour in ReleaseFast; clamp first with `@intFromFloat(@min(@max(x, min_f), max_f))` or use `std.math.lossyCast`",
        .{},
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, builtin_tok),
        .end = Pos.fromTokenEnd(tree, builtin_tok),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "intfromfloat-without-clamp: bare intFromFloat fires" {
    try testing.expectFires(check, R,
        \\fn setInterval(seconds: f64) void {
        \\    const sec: i64 = @intFromFloat(seconds);
        \\    _ = sec;
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: modf result fires" {
    try testing.expectFires(check, R,
        \\fn encodeTime(value: f64) i32 {
        \\    const modf = std.math.modf(value);
        \\    return @intFromFloat(modf.ipart);
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: @min guard suppresses" {
    try testing.expectNoFire(check,
        \\fn setInterval(seconds: f64) void {
        \\    const sec: i32 = @intFromFloat(@min(seconds, @as(f64, std.math.maxInt(i32))));
        \\    _ = sec;
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: @max guard suppresses" {
    try testing.expectNoFire(check,
        \\fn clampPositive(x: f64) u32 {
        \\    return @intFromFloat(@max(x, 0.0));
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: @round guard suppresses" {
    try testing.expectNoFire(check,
        \\fn rounded(x: f64) i32 {
        \\    return @intFromFloat(@round(x));
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: clamp identifier suppresses" {
    try testing.expectNoFire(check,
        \\fn clamped(x: f64) i32 {
        \\    return @intFromFloat(std.math.clamp(x, -1e9, 1e9));
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: and-range guard suppresses" {
    try testing.expectNoFire(check,
        \\fn convert(value: f64) ?i32 {
        \\    if (!(value >= -2147483648.0 and value < 2147483648.0)) return null;
        \\    const int: i32 = @intFromFloat(value);
        \\    return int;
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: or-range guard does not suppress (NaN passes)" {
    try testing.expectFires(check, R,
        \\fn setSize(value: f64) !u32 {
        \\    if (value < 0 or value > 4294967295.0) return error.OutOfRange;
        \\    return @intFromFloat(value);
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: single-side guard does not suppress" {
    try testing.expectFires(check, R,
        \\fn toUint(x: f64) u32 {
        \\    if (x > 4294967295.0) return 0;
        \\    return @intFromFloat(x);
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: runtime floor check suppresses" {
    try testing.expectNoFire(check,
        \\fn printNonNeg(p: *Printer, float: f64) void {
        \\    const floored: f64 = @floor(float);
        \\    const remainder: f64 = float - floored;
        \\    const is_integer = remainder == 0;
        \\    if (float < 1e15 and is_integer) {
        \\        const val = @intFromFloat(float);
        \\        _ = val;
        \\    }
        \\}
        \\
    );
}

test "intfromfloat-without-clamp: assert-only floor does not suppress" {
    try testing.expectFires(check, R,
        \\fn addFloatToInt(int: *u32, float: f64) void {
        \\    assert(@floor(float) == float);
        \\    int.* = int.* +| @intFromFloat(float);
        \\}
        \\
    );
}
