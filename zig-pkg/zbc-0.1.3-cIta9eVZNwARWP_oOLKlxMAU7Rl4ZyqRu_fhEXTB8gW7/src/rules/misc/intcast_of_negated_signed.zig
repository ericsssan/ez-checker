//! Detects `@intCast(-VAR)` — casting a negated runtime integer without
//! guarding against the minimum-value overflow.  If `VAR` is a signed integer
//! and holds `minInt(T)`, the negation wraps in ReleaseFast (silently produces
//! the wrong value) and panics in Debug/ReleaseSafe.  The correct form is
//! `@abs(VAR)` for the common "take the magnitude" pattern, or an explicit
//! range check before negating.
//!
//! Real-world instance:
//!   - ziglang/zig#23318 (fmtDurationSigned): `@as(u64, @intCast(-ns))` where
//!     `ns: i64` — if `ns == minInt(i64)`, negation overflows.  Fix: `@abs(ns)`.
//!
//! Detection (Tier 1, flat token walk):
//!   Pattern: `@intCast ( - identifier )` — 5 tokens.
//!   Fire at the `@intCast` builtin token.
//!   Does not fire for `@intCast(-1)` (integer literal — comptime-checked).

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");
const testing = @import("../../testing.zig");

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "intcast-of-negated-signed";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .intcast_of_negated_signed)) return;
    _ = cache;

    const tags = tree.tokens.items(.tag);
    if (tree.tokens.len < 5) return;
    const last_tok: Ast.TokenIndex = @intCast(tree.tokens.len -| 1);

    // AST pre-pass: token ranges where a variable is proven `<= 0` by a sign
    // guard.  Inside such a range `-x` is non-negative, so `@intCast(-x)` is
    // safe (the negate-the-magnitude idiom, e.g. `if (errno < 0) @intCast(-errno)`).
    var neg = try collectNegGuardedRanges(gpa, tree);
    defer neg.deinit(gpa);

    var t: Ast.TokenIndex = 0;
    while (t + 4 <= last_tok) : (t += 1) {
        // Pattern: @intCast ( - identifier )
        if (tags[t] != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t), "@intCast")) continue;
        if (tags[t + 1] != .l_paren) continue;
        if (tags[t + 2] != .minus) continue;
        if (tags[t + 3] != .identifier) continue;
        if (tags[t + 4] != .r_paren) continue;

        // Suppress when `x` is proven `<= 0` by an enclosing sign guard
        // (`if (x < 0) … @intCast(-x)` / `if (x >= 0) … else @intCast(-x)`):
        // then `-x >= 0` cannot overflow on the cast.  NOTE: this trades away
        // the minInt edge WITHIN such a guard (`-minInt` still overflows), but
        // the documented TP (zig#23318) is UNGUARDED and still fires.
        if (inNegGuardedRange(neg.items, tree.tokenSlice(t + 3), t)) continue;

        try report(gpa, problems, tree, t);
    }
}

const NegRange = struct { name: []const u8, start: Ast.TokenIndex, end: Ast.TokenIndex };

const GuardArm = enum { then, els };

/// If `cond` is a sign comparison against literal `0` on a bare identifier,
/// return the variable name and which arm proves it `<= 0`.
fn condSignGuard(tree: *const Ast, cond: Ast.Node.Index) ?struct { name: []const u8, arm: GuardArm } {
    const Cmp = enum { lt, le, gt, ge };
    const cmp: Cmp = switch (tree.nodeTag(cond)) {
        .less_than => .lt,
        .less_or_equal => .le,
        .greater_than => .gt,
        .greater_or_equal => .ge,
        else => return null,
    };
    const d = tree.nodeData(cond).node_and_node;
    // `V <cmp> 0`
    if (identNodeName(tree, d[0])) |name| {
        if (isZeroLiteral(tree, d[1])) return switch (cmp) {
            .lt, .le => .{ .name = name, .arm = .then }, // V<0 / V<=0  → then: V<=0
            .gt, .ge => .{ .name = name, .arm = .els }, // V>0 / V>=0  → else: V<=0
        };
    }
    // `0 <cmp> V`
    if (identNodeName(tree, d[1])) |name| {
        if (isZeroLiteral(tree, d[0])) return switch (cmp) {
            .gt, .ge => .{ .name = name, .arm = .then }, // 0>V / 0>=V  → then: V<=0
            .lt, .le => .{ .name = name, .arm = .els }, // 0<V / 0<=V  → else: V<=0
        };
    }
    return null;
}

fn collectNegGuardedRanges(gpa: std.mem.Allocator, tree: *const Ast) !std.ArrayListUnmanaged(NegRange) {
    var out: std.ArrayListUnmanaged(NegRange) = .empty;
    errdefer out.deinit(gpa);
    const ntags = tree.nodes.items(.tag);
    var ni: u32 = 1;
    while (ni < tree.nodes.len) : (ni += 1) {
        switch (ntags[ni]) {
            .if_simple, .@"if" => {},
            else => continue,
        }
        const node: Ast.Node.Index = @enumFromInt(ni);
        const iff = tree.fullIf(node) orelse continue;
        const g = condSignGuard(tree, iff.ast.cond_expr) orelse continue;
        const arm_node = switch (g.arm) {
            .then => iff.ast.then_expr,
            .els => iff.ast.else_expr.unwrap() orelse continue,
        };
        try out.append(gpa, .{
            .name = g.name,
            .start = tree.firstToken(arm_node),
            .end = tree.lastToken(arm_node),
        });
    }
    return out;
}

fn inNegGuardedRange(ranges: []const NegRange, name: []const u8, tok: Ast.TokenIndex) bool {
    for (ranges) |r| {
        if (tok >= r.start and tok <= r.end and std.mem.eql(u8, r.name, name)) return true;
    }
    return false;
}

fn identNodeName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .identifier) return null;
    return tree.tokenSlice(tree.nodeMainToken(node));
}

fn isZeroLiteral(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .number_literal) return false;
    const v = std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch return false;
    return v == 0;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    intcast_tok: Ast.TokenIndex,
) !void {
    const name = tree.tokenSlice(intcast_tok + 3);
    const msg = try std.fmt.allocPrint(
        gpa,
        "`@intCast(-{s})` — if `{s}` is a signed integer at its minimum value, `-{s}` overflows before the cast; use `@abs({s})` to safely get the magnitude, or guard with a range check",
        .{ name, name, name, name },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, intcast_tok),
        .end = Pos.fromTokenEnd(tree, intcast_tok + 4),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "intcast-of-negated-signed: fires on @intCast(-var)" {
    try testing.expectFires(check, R,
        \\fn formatDuration(ns: i64) u64 {
        \\    return @as(u64, @intCast(-ns));
        \\}
        \\
    );
}

test "intcast-of-negated-signed: fires on direct @intCast(-x)" {
    try testing.expectFires(check, R,
        \\fn negate(x: i32) u32 {
        \\    return @intCast(-x);
        \\}
        \\
    );
}

test "intcast-of-negated-signed: integer literal does not fire" {
    try testing.expectNoFire(check,
        \\fn negative() i32 {
        \\    return @intCast(-1);
        \\}
        \\
    );
}

test "intcast-of-negated-signed: intCast without negation does not fire" {
    try testing.expectNoFire(check,
        \\fn cast(x: i64) u32 {
        \\    return @intCast(x);
        \\}
        \\
    );
}

test "intcast-of-negated-signed: @abs is the correct form, does not fire" {
    try testing.expectNoFire(check,
        \\fn magnitude(x: i64) u64 {
        \\    return @abs(x);
        \\}
        \\
    );
}

test "intcast-of-negated-signed: then-branch of `if (x < 0)` does not fire (errno idiom)" {
    try testing.expectNoFire(check,
        \\fn check(fd: i32) void {
        \\    const result = setsockopt(fd);
        \\    if (result < 0) {
        \\        const err: i32 = @intCast(-result);
        \\        log(err);
        \\    }
        \\}
        \\
    );
}

test "intcast-of-negated-signed: else-branch of `if (x >= 0)` does not fire (slide idiom)" {
    try testing.expectNoFire(check,
        \\fn adjust(pc: u64, slide: i64) u64 {
        \\    return if (slide >= 0)
        \\        pc -| @as(u64, @intCast(slide))
        \\    else
        \\        pc + @as(u64, @intCast(-slide));
        \\}
        \\
    );
}

test "intcast-of-negated-signed: unguarded negation still fires (zig#23318 class)" {
    try testing.expectFires(check, R,
        \\fn formatDuration(ns: i64) u64 {
        \\    return @as(u64, @intCast(-ns));
        \\}
        \\
    );
}

test "intcast-of-negated-signed: negation of a DIFFERENT var than the guard still fires" {
    try testing.expectFires(check, R,
        \\fn f(a: i64, b: i64) u64 {
        \\    if (a < 0) {
        \\        return @as(u64, @intCast(-b));
        \\    }
        \\    return 0;
        \\}
        \\
    );
}
