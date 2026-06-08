//! Detects `@as(f32, @floatFromInt(expr))` — narrowing an integer to f32.
//!
//! `f32` represents integers exactly only up to 2²⁴ (16,777,216).  For
//! integers larger than that, `@floatFromInt` silently rounds to the
//! nearest representable f32 value.  When the resulting f32 is used in
//! bounds checks, size arithmetic, or offset calculations, the rounding
//! invalidates the check — a value of 33,554,433 rounds to 33,554,432,
//! passing a guard that should have caught it.
//!
//! The correct type is `f64`, which represents integers exactly up to 2⁵³.
//! For cases where f32 is genuinely needed (e.g., GPU vertex buffers),
//! a saturating clamp should precede the cast.
//!
//! Real-world shape: oven-sh/bun#30134 (CSS parser: bounds checks on typed
//! array offsets used `@as(f32, @floatFromInt(...))`, silently rounding
//! large values and bypassing OOB guards).
//!
//! Detection (Tier 1, token walk):
//!   6-token pattern:
//!     t+0: builtin("@as")   t+1: l_paren   t+2: identifier("f32")
//!     t+3: comma            t+4: builtin("@floatFromInt")   t+5: l_paren
//!   Fire at the `@as` builtin token.
//!
//!   Suppressions (any of the following within the inner-expression window):
//!   1. `& MASK` where MASK ≤ 0xFFFF — 16-bit mask bounds the value to ≤ 65535,
//!      exactly representable in f32.  Covers `@floatFromInt(rgba & 0xFF)`.
//!   2. Colour-channel field access: argument is `RECV.{r,g,b,a,red,green,blue,alpha}`.
//!      Colour channels are u8 (0-255), all exactly representable in f32.
//!   3. Divided-by-255: `/ 255` or `/ 255.0` within 30 tokens of the inner
//!      argument.  Division by 255 implies the integer is in [0, 255] range.

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const tokens = @import("../../ast/tokens.zig");
const testing = @import("../../testing.zig");

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "f32-narrowing-int-to-float";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .f32_narrowing_int_to_float)) return;

    const tags = tree.tokens.items(.tag);
    const last_tok: Ast.TokenIndex = @intCast(tree.tokens.len -| 1);

    var t: Ast.TokenIndex = 0;
    while (t + 5 <= last_tok) : (t += 1) {
        // Pattern: @as ( f32 , @floatFromInt (
        if (tags[t] != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t), "@as")) continue;
        if (tags[t + 1] != .l_paren) continue;
        if (tags[t + 2] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t + 2), "f32")) continue;
        if (tags[t + 3] != .comma) continue;
        if (tags[t + 4] != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t + 4), "@floatFromInt")) continue;
        if (tags[t + 5] != .l_paren) continue;

        // SEMANTIC: resolve the source integer's width.  `f32` represents every
        // integer in [-2²⁴, 2²⁴] exactly, so any source of ≤24 bits (u8/u16/i16/
        // u24/i24 …) converts losslessly — no rounding, not this bug.  This
        // subsumes the syntactic proxies below (colour channels are u8, masks/
        // divisors bound to ≤16 bits) and generalises to any narrow type/alias.
        // No-op without the type engine, so the token proxies remain as fallback.
        if (sourceExactInF32(cache, tags, t + 5, last_tok)) continue;

        // Suppress when the argument ends with `& MASK` where MASK ≤ 0xFFFF.
        if (hasSmallBitAndMask(tags, tree, t + 6, last_tok)) continue;
        // Suppress colour-channel field access: RECV.{r,g,b,a,red,green,blue,alpha}.
        if (hasColorChannelArg(tags, tree, t + 6, last_tok)) continue;
        // Suppress when the result is divided by a small constant (255, 256, 100, etc.),
        // either forward (… / 255.0 after the cast) or backward (val/255.0 * @as(f32,…)).
        if (hasDivBySmallConst(tags, tree, t, t + 6, last_tok)) continue;

        try report(gpa, problems, tree, t);
    }
}

/// True iff the `@floatFromInt` argument resolves to an integer type of ≤24
/// bits, which `f32` represents exactly (every integer in [-2²⁴, 2²⁴] is
/// exactly representable, and a ≤24-bit value never exceeds that range).  Such
/// a conversion is lossless, so the rule does not apply.
///
/// `lparen_tok` is the `(` of `@floatFromInt`; the argument spans from the next
/// token to the token before the matching `)`.  Returns false when the type
/// engine is unavailable, the parens are unbalanced/empty, or the source isn't
/// a ≤24-bit integer (in which case the syntactic suppressions still apply).
fn sourceExactInF32(
    cache: *file_cache_mod.FileCache,
    tags: []const std.zig.Token.Tag,
    lparen_tok: Ast.TokenIndex,
    last_tok: Ast.TokenIndex,
) bool {
    if (tags[lparen_tok] != .l_paren) return false;
    // Find the `)` matching the `@floatFromInt` `(` by paren-depth balance.
    var depth: u32 = 0;
    var close: Ast.TokenIndex = lparen_tok;
    var k = lparen_tok;
    while (k <= last_tok) : (k += 1) {
        switch (tags[k]) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) {
                    close = k;
                    break;
                }
            },
            else => {},
        }
    }
    if (depth != 0) return false;
    const arg_start = lparen_tok + 1;
    if (close == 0 or close - 1 < arg_start) return false; // empty `()`
    const info = cache.intInfoOfExpr(arg_start, close - 1) orelse return false;
    return info.bits <= 24;
}

/// Returns true when the @floatFromInt argument ends with `& MASK` where
/// MASK is a hex/decimal literal ≤ 0xFFFF (65535).  Scans forward from
/// `inner_start` (first token inside the `(`) within a 20-token window
/// looking for `r_paren` preceded by a small number_literal preceded by `&`.
fn hasSmallBitAndMask(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    inner_start: Ast.TokenIndex,
    last_tok: Ast.TokenIndex,
) bool {
    const window: Ast.TokenIndex = 20;
    const end = @min(inner_start + window, last_tok);
    var k = inner_start;
    while (k + 2 <= end) : (k += 1) {
        if (tags[k] != .ampersand) continue;
        if (tags[k + 1] != .number_literal) continue;
        if (tags[k + 2] != .r_paren) continue;
        const mask_str = tree.tokenSlice(k + 1);
        const mask = std.fmt.parseUnsigned(u64, mask_str, 0) catch continue;
        if (mask <= 0xFFFF) return true;
    }
    return false;
}

/// Returns true when the `@floatFromInt` argument is a colour-channel field
/// access of the form `receiver.{r,g,b,a,red,green,blue,alpha}`.
/// Colour channels are always u8 (0-255) — all values fit exactly in f32.
fn hasColorChannelArg(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    inner_start: Ast.TokenIndex,
    last_tok: Ast.TokenIndex,
) bool {
    // Pattern: identifier . COLOR_FIELD
    if (inner_start + 2 > last_tok) return false;
    if (tags[inner_start] != .identifier) return false;
    if (tags[inner_start + 1] != .period) return false;
    if (tags[inner_start + 2] != .identifier) return false;
    const field = tree.tokenSlice(inner_start + 2);
    return std.mem.eql(u8, field, "r") or
        std.mem.eql(u8, field, "g") or
        std.mem.eql(u8, field, "b") or
        std.mem.eql(u8, field, "a") or
        std.mem.eql(u8, field, "red") or
        std.mem.eql(u8, field, "green") or
        std.mem.eql(u8, field, "blue") or
        std.mem.eql(u8, field, "alpha");
}

/// True iff the `@as(f32, @floatFromInt(…))` expression is divided by a small
/// constant that bounds the integer to an exactly-representable f32 range.
///
/// Divisors accepted: 255, 255.0 (u8 colour channel), 256, 256.0 (8-bit
/// palette index), 100, 100.0 (percentage 0-100).
///
/// Scans both forward (result / const after the cast) and backward (the cast
/// is the RHS of `x/const * @as(f32, …)`).
fn hasDivBySmallConst(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    as_tok: Ast.TokenIndex,
    inner_start: Ast.TokenIndex,
    last_tok: Ast.TokenIndex,
) bool {
    // Forward scan: `@as(f32, @floatFromInt(…)) / CONST`
    const fwd_window: Ast.TokenIndex = 30;
    const fwd_end = @min(inner_start + fwd_window, last_tok);
    var k = inner_start;
    while (k + 1 <= fwd_end) : (k += 1) {
        if (tags[k] == .slash and tags[k + 1] == .number_literal) {
            if (isSmallDivisor(tree.tokenSlice(k + 1))) return true;
        }
    }
    // Backward scan: `EXPR / CONST * @as(f32, …)` — the division precedes the cast.
    const bwd_window: Ast.TokenIndex = 6;
    const bwd_start: Ast.TokenIndex = if (as_tok >= bwd_window) as_tok - bwd_window else 0;
    k = bwd_start;
    while (k + 1 < as_tok) : (k += 1) {
        if (tags[k] == .slash and tags[k + 1] == .number_literal) {
            if (isSmallDivisor(tree.tokenSlice(k + 1))) return true;
        }
    }
    return false;
}

fn isSmallDivisor(s: []const u8) bool {
    return std.mem.eql(u8, s, "255") or
        std.mem.eql(u8, s, "255.0") or
        std.mem.eql(u8, s, "256") or
        std.mem.eql(u8, s, "256.0") or
        std.mem.eql(u8, s, "100") or
        std.mem.eql(u8, s, "100.0");
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    as_tok: Ast.TokenIndex,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`@as(f32, @floatFromInt(…))` narrows an integer to f32, which only represents integers exactly up to 2²⁴ (16,777,216); larger values are silently rounded, defeating bounds checks and size arithmetic; use `@as(f64, @floatFromInt(…))` for correctness, or clamp first if f32 is genuinely required",
        .{},
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, as_tok),
        .end = Pos.fromTokenEnd(tree, as_tok),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "f32-narrowing-int-to-float: basic pattern fires" {
    try testing.expectFires(check, R,
        \\fn checkBounds(offset: usize) f32 {
        \\    return @as(f32, @floatFromInt(offset));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: f64 does not fire" {
    try testing.expectNoFire(check,
        \\fn checkBounds(offset: usize, len: usize) bool {
        \\    return @as(f64, @floatFromInt(offset)) < @as(f64, @floatFromInt(len));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: non-floatFromInt does not fire" {
    try testing.expectNoFire(check,
        \\fn convert(x: f64) f32 {
        \\    return @as(f32, @floatCast(x));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: & 0xFF mask suppresses" {
    try testing.expectNoFire(check,
        \\fn colorChan(rgba: u32) f32 {
        \\    return @as(f32, @floatFromInt(rgba & 0xFF)) / 255.0;
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: & 0xFFFF mask suppresses" {
    try testing.expectNoFire(check,
        \\fn toFloat(x: u32) f32 {
        \\    return @as(f32, @floatFromInt(x & 0xFFFF));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: & 0x1FFFF mask still fires (> 16-bit)" {
    try testing.expectFires(check, R,
        \\fn toFloat(x: u32) f32 {
        \\    return @as(f32, @floatFromInt(x & 0x1FFFF));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: colour field .r suppresses" {
    try testing.expectNoFire(check,
        \\fn toLinear(c: Color) f32 {
        \\    return @as(f32, @floatFromInt(c.r)) / 255.0;
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: colour field .alpha suppresses" {
    try testing.expectNoFire(check,
        \\fn alpha(c: Color) f32 {
        \\    return @as(f32, @floatFromInt(c.alpha));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: divided by 255.0 suppresses" {
    try testing.expectNoFire(check,
        \\fn toFloat(val: u8) f32 {
        \\    return @as(f32, @floatFromInt(val)) / 255.0;
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: divided by 255 (no decimal) suppresses" {
    try testing.expectNoFire(check,
        \\fn toFloat(r: u8) f32 {
        \\    return @as(f32, @floatFromInt(r)) / 255;
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: divided by 256 suppresses" {
    try testing.expectNoFire(check,
        \\fn toHue(i: u8) f32 {
        \\    return @as(f32, @floatFromInt(i)) / 256.0;
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: divided by 100 suppresses" {
    try testing.expectNoFire(check,
        \\fn toPercent(q: u8) f32 {
        \\    return @as(f32, @floatFromInt(q)) / 100;
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: backward / 255 suppresses" {
    try testing.expectNoFire(check,
        \\fn blend(a: u8, val: u8) f32 {
        \\    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
        \\    return af * @as(f32, @floatFromInt(val));
        \\}
        \\
    );
}

test "f32-narrowing-int-to-float: shifted & 0xFF mask suppresses" {
    try testing.expectNoFire(check,
        \\fn colorChan(rgba: u32) f32 {
        \\    return @as(f32, @floatFromInt((rgba >> 8) & 0xFF)) / 255.0;
        \\}
        \\
    );
}
