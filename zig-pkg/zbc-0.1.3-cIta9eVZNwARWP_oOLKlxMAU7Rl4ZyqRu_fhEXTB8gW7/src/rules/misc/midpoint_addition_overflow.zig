//! Detects `(a + b) / 2` — the classic binary-search midpoint overflow.
//! If `a` and `b` are both at their maximum values, `a + b` overflows the
//! integer type before the division, producing a wrong or wrapped midpoint.
//! The correct form is `a + (b - a) / 2` (or `left + (right - left) / 2`).
//!
//! Real-world instances:
//!   - ziglang/zig#20029 (std.sort.upperBound): `mid = (right + left) / 2` — overflow
//!     for bounds near `maxInt(usize)`.  Fix: `left + (right - left) / 2`.
//!   - ziglang/zig#18718 (std.sort.lowerBound / equalRange): same pattern.
//!
//! Detection (Tier 1, flat token walk):
//!   Pattern: `( identifier + identifier ) / 2`  — 7 tokens.
//!   Fire at the `(` token.
//!   Also catches `( identifier + identifier ) / 2` when the literal is `number_literal("2")`.
//!   Does NOT fire for `(a + b) / other_var` (not a division by 2) or
//!   `(a + b) / 2` inside a `comptime` expression (compiler catches overflow).

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");
const testing = @import("../../testing.zig");

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "midpoint-addition-overflow";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .midpoint_addition_overflow)) return;

    const tags = tree.tokens.items(.tag);
    if (tree.tokens.len < 7) return;
    const last_tok: Ast.TokenIndex = @intCast(tree.tokens.len -| 1);

    // Map identifier-reference AST nodes by their main token so the type
    // engine can resolve the operand types.  Empty when engine is absent.
    var ident_nodes: std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.Index) = .empty;
    defer ident_nodes.deinit(gpa);
    {
        var ni: u32 = 0;
        while (ni < tree.nodes.len) : (ni += 1) {
            const node: Ast.Node.Index = @enumFromInt(ni);
            if (tree.nodeTag(node) == .identifier) {
                try ident_nodes.put(gpa, tree.nodeMainToken(node), node);
            }
        }
    }

    var t: Ast.TokenIndex = 0;
    while (t + 6 <= last_tok) : (t += 1) {
        // Pattern: ( identifier + identifier ) / 2
        if (tags[t] != .l_paren) continue;
        if (tags[t + 1] != .identifier) continue;
        if (tags[t + 2] != .plus) continue;
        if (tags[t + 3] != .identifier) continue;
        if (tags[t + 4] != .r_paren) continue;
        if (tags[t + 5] != .slash) continue;
        if (tags[t + 6] != .number_literal) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t + 6), "2")) continue;

        const a = tree.tokenSlice(t + 1);
        const b = tree.tokenSlice(t + 3);

        // Type-engine suppression: if the type engine resolves either
        // operand to a float type (f16/f32/f64/f128), addition cannot
        // overflow in the integer sense — suppress.
        if (operandIsFloat(cache, &ident_nodes, t + 1) or
            operandIsFloat(cache, &ident_nodes, t + 3)) continue;

        // Syntactic fallback: suppress when either operand is declared
        // with float arithmetic nearby (catches @floatFromInt / f64 decls
        // when the type engine is absent).
        if (hasFloatDecl(tags, tree, t, a) or hasFloatDecl(tags, tree, t, b)) continue;
        try report(gpa, problems, tree, t, a, b);
    }
}

/// True iff the identifier at `tok` resolves to a float type via the type engine.
fn operandIsFloat(
    cache: *file_cache_mod.FileCache,
    ident_nodes: *const std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.Index),
    tok: Ast.TokenIndex,
) bool {
    const node = ident_nodes.get(tok) orelse return false;
    const tyname = cache.typeNameOfNode(node) orelse return false;
    return std.mem.eql(u8, tyname, "f16") or
        std.mem.eql(u8, tyname, "f32") or
        std.mem.eql(u8, tyname, "f64") or
        std.mem.eql(u8, tyname, "f128") or
        std.mem.eql(u8, tyname, "f80");
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    lparen_tok: Ast.TokenIndex,
    a: []const u8,
    b: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`({s} + {s}) / 2` overflows when `{s} + {s}` exceeds the integer type's maximum; use `{s} + ({s} - {s}) / 2` to compute the midpoint without overflow",
        .{ a, b, a, b, a, b, a },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, lparen_tok),
        .end = Pos.fromTokenEnd(tree, lparen_tok + 6),
        .message = msg,
    });
}

/// Returns true when the nearest `const/var VAR_NAME = …` declaration visible
/// before `anchor` contains a float marker in its initialiser: a `@floatFromInt`
/// or `@floatCast` builtin, a float type identifier (`f32`, `f64`, `f128`,
/// `f16`), or a number literal that contains a `.` (e.g. `255.0`).
/// Scans backward up to 150 tokens to find the declaration, then forward up
/// to 60 tokens into the initialiser for the marker.
fn hasFloatDecl(
    tags: []const std.zig.Token.Tag,
    tree: *const Ast,
    anchor: Ast.TokenIndex,
    var_name: []const u8,
) bool {
    const back_window: Ast.TokenIndex = 150;
    const fwd_window: Ast.TokenIndex = 60;
    const start: Ast.TokenIndex = if (anchor >= back_window) anchor - back_window else 0;
    var k = anchor;
    while (k > start + 1) {
        k -= 1;
        if (tags[k] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k), var_name)) continue;
        if (tags[k - 1] != .keyword_const and tags[k - 1] != .keyword_var) continue;
        // Found `const/var VAR_NAME`; scan forward for float markers.
        const decl_end = @min(k + fwd_window, anchor);
        var j = k + 1;
        while (j < decl_end) : (j += 1) {
            switch (tags[j]) {
                .builtin => {
                    const s = tree.tokenSlice(j);
                    if (std.mem.eql(u8, s, "@floatFromInt") or
                        std.mem.eql(u8, s, "@floatCast")) return true;
                },
                .identifier => {
                    const s = tree.tokenSlice(j);
                    if (std.mem.eql(u8, s, "f32") or
                        std.mem.eql(u8, s, "f64") or
                        std.mem.eql(u8, s, "f128") or
                        std.mem.eql(u8, s, "f16")) return true;
                },
                .number_literal => {
                    if (std.mem.indexOf(u8, tree.tokenSlice(j), ".") != null) return true;
                },
                else => {},
            }
        }
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────

test "midpoint-addition-overflow: fires on (left + right) / 2" {
    try testing.expectFires(check, R,
        \\fn midpoint(left: usize, right: usize) usize {
        \\    return (left + right) / 2;
        \\}
        \\
    );
}

test "midpoint-addition-overflow: fires on binary search pattern" {
    try testing.expectFires(check, R,
        \\fn binarySearch(items: []const u32, target: u32) ?usize {
        \\    var left: usize = 0;
        \\    var right: usize = items.len;
        \\    while (left < right) {
        \\        const mid = (left + right) / 2;
        \\        if (items[mid] == target) return mid;
        \\        if (items[mid] < target) left = mid + 1 else right = mid;
        \\    }
        \\    return null;
        \\}
        \\
    );
}

test "midpoint-addition-overflow: correct form does not fire" {
    try testing.expectNoFire(check,
        \\fn midpoint(left: usize, right: usize) usize {
        \\    return left + (right - left) / 2;
        \\}
        \\
    );
}

test "midpoint-addition-overflow: division by non-2 does not fire" {
    try testing.expectNoFire(check,
        \\fn third(a: usize, b: usize) usize {
        \\    return (a + b) / 3;
        \\}
        \\
    );
}

test "midpoint-addition-overflow: variable divisor does not fire" {
    try testing.expectNoFire(check,
        \\fn avg(a: usize, b: usize, n: usize) usize {
        \\    return (a + b) / n;
        \\}
        \\
    );
}

test "midpoint-addition-overflow: f32 pixel operands do not fire" {
    try testing.expectNoFire(check,
        \\fn encode(rgba: []const u8) void {
        \\    const al: f32 = @as(f32, @floatFromInt(rgba[3])) / 255.0;
        \\    const r = @as(f32, @floatFromInt(rgba[0])) * al;
        \\    const g = @as(f32, @floatFromInt(rgba[1])) * al;
        \\    _ = (r + g) / 2;
        \\}
        \\
    );
}
