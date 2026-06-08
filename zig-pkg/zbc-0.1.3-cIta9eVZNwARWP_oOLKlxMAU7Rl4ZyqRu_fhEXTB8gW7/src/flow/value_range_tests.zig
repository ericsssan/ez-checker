//! Tests for the standalone nonzero value-range oracle.

const std = @import("std");
const Ast = std.zig.Ast;
const value_range = @import("value_range.zig");

/// Parse `src`, locate the first fn body, find the `[` token of the
/// subscript on array `arr`, and ask whether `target` is provably nonzero
/// there.  Returns the oracle's answer.
fn proveAt(src: [:0]const u8, target: []const u8, arr: []const u8) !bool {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);

    const body = firstFnBody(&tree) orelse return error.NoFnBody;
    const lbracket = subscriptLBracket(&tree, arr) orelse return error.NoSubscript;
    return value_range.provesNonzero(gpa, &tree, body, target, lbracket, null);
}

fn firstFnBody(tree: *const Ast) ?Ast.Node.Index {
    var ni: u32 = 0;
    while (ni < tree.nodes.len) : (ni += 1) {
        const node: Ast.Node.Index = @enumFromInt(ni);
        if (tree.nodeTag(node) != .fn_decl) continue;
        // fn_decl data: { proto, body }.
        const data = tree.nodeData(node).node_and_node;
        return data[1];
    }
    return null;
}

/// First `[` token preceded by identifier `arr`.
fn subscriptLBracket(tree: *const Ast, arr: []const u8) ?Ast.TokenIndex {
    const tags = tree.tokens.items(.tag);
    var t: Ast.TokenIndex = 1;
    while (t < tags.len) : (t += 1) {
        if (tags[t] != .l_bracket) continue;
        if (tags[t - 1] != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenSlice(t - 1), arr)) return t;
    }
    return null;
}

test "nonzero: bare param is unknown (fires)" {
    try std.testing.expect(!try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: i > 0 guard in then-arm" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (i > 0) {
        \\        return buf[i - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: i > <non-negative literal> guard (generalized lower bound)" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (i > 5) {
        \\        return buf[i - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: i > other.len guard (.len operand is provably >= 0)" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8, other: []const u8) u8 {
        \\    if (i > other.len) {
        \\        return buf[i - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: `x += 1` makes an unsigned x nonzero (post-increment look-back)" {
    try std.testing.expect(try proveAt(
        \\fn f(buf: []const u8) u8 {
        \\    var i: usize = 0;
        \\    i += 1;
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: i != 0 guard" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (i != 0) return buf[i - 1];
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: i >= 1 guard" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (i >= 1) return buf[i - 1];
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: 0 < i guard" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (0 < i) return buf[i - 1];
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: early return on zero (divergence)" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (i == 0) return 0;
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: use in else-arm of i==0 is nonzero" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, buf: []const u8) u8 {
        \\    if (i == 0) {
        \\        return 0;
        \\    } else {
        \\        return buf[i - 1];
        \\    }
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: positive-literal assignment" {
    try std.testing.expect(try proveAt(
        \\fn f(buf: []const u8) u8 {
        \\    var i: usize = 3;
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: zero-literal assignment is unsafe" {
    try std.testing.expect(!try proveAt(
        \\fn f(buf: []const u8) u8 {
        \\    var i: usize = 0;
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: merge of nonzero/zero arms is unsafe" {
    try std.testing.expect(!try proveAt(
        \\fn f(c: bool, buf: []const u8) u8 {
        \\    var i: usize = 1;
        \\    if (c) {
        \\        i = 5;
        \\    } else {
        \\        i = 0;
        \\    }
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: guard in while condition refines body" {
    try std.testing.expect(try proveAt(
        \\fn f(i_in: usize, buf: []const u8) u8 {
        \\    var i = i_in;
        \\    while (i > 0) {
        \\        const x = buf[i - 1];
        \\        if (x == 0) return 0;
        \\        i -= 1;
        \\    }
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: and-chain guard (i > 0 and c)" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, c: bool, buf: []const u8) u8 {
        \\    if (i > 0 and c) return buf[i - 1];
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: unrelated guard does not prove" {
    try std.testing.expect(!try proveAt(
        \\fn f(i: usize, j: usize, buf: []const u8) u8 {
        \\    if (j > 0) return buf[i - 1];
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

test "nonzero: reassignment after guard clears fact" {
    try std.testing.expect(!try proveAt(
        \\fn f(i_in: usize, other: usize, buf: []const u8) u8 {
        \\    var i = i_in;
        \\    if (i > 0) {
        \\        i = other;
        \\        return buf[i - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    , "i", "buf"));
}

// ── container non-empty ──────────────────────────────────────

/// Query `provesNonempty(container)` at the `[` token after identifier `arr`.
fn proveNonemptyAt(src: [:0]const u8, container: []const u8, arr: []const u8) !bool {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);
    const body = firstFnBody(&tree) orelse return error.NoFnBody;
    const lbracket = subscriptLBracket(&tree, arr) orelse return error.NoSubscript;
    return value_range.provesNonempty(gpa, &tree, body, container, lbracket, null);
}

test "nonempty: bare arr.len-1 is unknown (fires)" {
    try std.testing.expect(!try proveNonemptyAt(
        \\fn f(arr: []const u8) u8 {
        \\    return arr[arr.len - 1];
        \\}
        \\
    , "arr", "arr"));
}

test "nonempty: arr.len > 0 guard" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn f(arr: []const u8) u8 {
        \\    if (arr.len > 0) return arr[arr.len - 1];
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

test "nonempty: early return on empty (divergence)" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn f(arr: []const u8) u8 {
        \\    if (arr.len == 0) return 0;
        \\    return arr[arr.len - 1];
        \\}
        \\
    , "arr", "arr"));
}

test "nonempty: arr.len != 0 guard" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn f(arr: []const u8) u8 {
        \\    if (arr.len != 0) return arr[arr.len - 1];
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

test "nonempty: dotted path self.items" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn f(self: *Foo) u8 {
        \\    if (self.items.len > 0) return self.items[self.items.len - 1];
        \\    return 0;
        \\}
        \\
    , "self.items", "items"));
}

test "nonempty: clear after guard is unsafe" {
    try std.testing.expect(!try proveNonemptyAt(
        \\fn f(arr: *std.ArrayList(u8)) u8 {
        \\    if (arr.len > 0) {
        \\        arr.clearRetainingCapacity();
        \\        return arr[arr.len - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

test "nonempty: reassignment after guard is unsafe" {
    try std.testing.expect(!try proveNonemptyAt(
        \\fn f(arr: []const u8, other: []const u8) u8 {
        \\    if (arr.len > 0) {
        \\        arr = other;
        \\        return arr[arr.len - 1];
        \\    }
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

test "nonempty: early-return with OR guard (len==0 or empty)" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn tail(self: *Foo) u8 {
        \\    if (self.buffer.len == 0 or self.empty()) return 0;
        \\    return self.buffer[(self.index) % self.buffer.len];
        \\}
        \\
    , "self.buffer", "buffer"));
}

test "nonzero: early-return with OR guard (i==0 or other)" {
    try std.testing.expect(try proveAt(
        \\fn f(i: usize, c: bool, buf: []const u8) u8 {
        \\    if (i == 0 or c) return 0;
        \\    return buf[i - 1];
        \\}
        \\
    , "i", "buf"));
}

test "nonempty: unrelated container guard does not prove" {
    try std.testing.expect(!try proveNonemptyAt(
        \\fn f(arr: []const u8, other: []const u8) u8 {
        \\    if (other.len > 0) return arr[arr.len - 1];
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

// ── len-bound local aliases (n == c.len) ─────────────────────

test "alias: scalar guard proves container nonempty (n=c.len, if n>0, c[c.len-1])" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn f(arr: []const u8) u8 {
        \\    const n = arr.len;
        \\    if (n > 0) return arr[arr.len - 1];
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

test "alias: scalar early-return proves container nonempty" {
    try std.testing.expect(try proveNonemptyAt(
        \\fn f(arr: []const u8) u8 {
        \\    const n = arr.len;
        \\    if (n == 0) return 0;
        \\    return arr[arr.len - 1];
        \\}
        \\
    , "arr", "arr"));
}

test "alias: container guard proves scalar nonzero (n=c.len, if c.len>0, buf[n-1])" {
    try std.testing.expect(try proveAt(
        \\fn f(arr: []const u8, buf: []const u8) u8 {
        \\    const n = arr.len;
        \\    if (arr.len > 0) return buf[n - 1];
        \\    return 0;
        \\}
        \\
    , "n", "buf"));
}

test "alias: container mutated after snapshot is unsafe" {
    try std.testing.expect(!try proveNonemptyAt(
        \\fn f(arr: *std.ArrayList(u8)) u8 {
        \\    const n = arr.len;
        \\    arr.clearRetainingCapacity();
        \\    if (n > 0) return arr[arr.len - 1];
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

test "alias: unrelated container not proven by scalar guard" {
    try std.testing.expect(!try proveNonemptyAt(
        \\fn f(arr: []const u8, other: []const u8) u8 {
        \\    const n = other.len;
        \\    if (n > 0) return arr[arr.len - 1];
        \\    return 0;
        \\}
        \\
    , "arr", "arr"));
}

// ── applyCmp: lit >= 2 (N-bounded guards) ────────────────────

test "nonzero: if (n < 2) return diverges, fall-through n >= 2 >= 1" {
    try std.testing.expect(try proveAt(
        \\fn f(n: usize, buf: []const u8) u8 {
        \\    if (n < 2) return 0;
        \\    return buf[n - 1];
        \\}
        \\
    , "n", "buf"));
}

test "nonzero: if (n >= 3) then n nonzero" {
    try std.testing.expect(try proveAt(
        \\fn f(n: usize, buf: []const u8) u8 {
        \\    if (n >= 3) return buf[n - 1];
        \\    return 0;
        \\}
        \\
    , "n", "buf"));
}

test "nonzero: if (2 > n) return diverges, fall-through n >= 2 >= 1 (flipped)" {
    try std.testing.expect(try proveAt(
        \\fn f(n: usize, buf: []const u8) u8 {
        \\    if (2 > n) return 0;
        \\    return buf[n - 1];
        \\}
        \\
    , "n", "buf"));
}

test "nonzero: if (n == 0) and if (n < 2) both still nonzero in fall-through" {
    try std.testing.expect(try proveAt(
        \\fn f(n: usize, buf: []const u8) u8 {
        \\    if (n < 5) return 0;
        \\    return buf[n - 1];
        \\}
        \\
    , "n", "buf"));
}

// ── DiffAlias: n = A - B, n nonzero → A nonzero ──────────────
// These tests use subtrahends that are provably non-negative WITHOUT the type
// engine (literal 0 or .len field), so they work in the cache-null test harness.
// The real-world case (identifier subtrahend, e.g. `range.end - range.start`)
// requires ZLS confirmation that the subtrahend is unsigned.

test "diff-alias: n = end - 0, if (n == 0) return, buf[end - 1] suppressed" {
    // Subtrahend is literal 0: operandProvablyNonneg = true, no type engine needed.
    try std.testing.expect(try proveAt(
        \\fn f(end: usize, buf: []const u8) u8 {
        \\    const n = end - 0;
        \\    if (n == 0) return 0;
        \\    return buf[end - 1];
        \\}
        \\
    , "end", "buf"));
}

test "diff-alias: n = end - other.len, if (n == 0) return, buf[end - 1] suppressed" {
    // Subtrahend is .len (provably >= 0), no type engine needed.
    try std.testing.expect(try proveAt(
        \\fn f(end: usize, other: []const u8, buf: []const u8) u8 {
        \\    const n = end - other.len;
        \\    if (n == 0) return 0;
        \\    return buf[end - 1];
        \\}
        \\
    , "end", "buf"));
}

test "diff-alias: n = end - 0, if (n < 2) return, buf[end - 1] suppressed (combined)" {
    // Both the lit>=2 applyCmp extension AND the DiffAlias are exercised.
    try std.testing.expect(try proveAt(
        \\fn f(end: usize, buf: []const u8) u8 {
        \\    const n = end - 0;
        \\    if (n < 2) return 0;
        \\    return buf[end - 1];
        \\}
        \\
    , "end", "buf"));
}

test "diff-alias: unrelated var not proven" {
    try std.testing.expect(!try proveAt(
        \\fn f(end: usize, start: usize, other: usize, buf: []const u8) u8 {
        \\    const n = end - 0;
        \\    if (n == 0) return 0;
        \\    return buf[other - 1];
        \\}
        \\
    , "other", "buf"));
}

test "diff-alias: rebinding end clears diff fact" {
    try std.testing.expect(!try proveAt(
        \\fn f(end: usize, buf: []const u8) u8 {
        \\    const n = end - 0;
        \\    if (n == 0) return 0;
        \\    const end2 = end;
        \\    _ = end2;
        \\    var end_mut: usize = 0;
        \\    end_mut = end;
        \\    return buf[end_mut - 1];
        \\}
        \\
    , "end_mut", "buf"));
}
