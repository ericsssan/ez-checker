//! Tagged-union payload early-exit detector.  An assignment
//!   `<path> = .{ .<Tag> = <expr> };`
//! where `<expr>` contains a `try` (or `catch ... { return; }` shape
//! captured by keyword_try) causes the union tag to be written to the
//! result location BEFORE the payload expression is evaluated.  If the
//! payload expression exits early via `try`, the LHS is left with the
//! new tag but the payload bytes from the PREVIOUS variant — garbage
//! state that later code (including errdefer cleanups) may misinterpret.
//!
//! Real-world: oven-sh/bun#29422.
//!
//! Fix: hoist the fallible expression into a `const` before the literal:
//!   const val = try computeErr();
//!   resolve.value = .{ .err = val };

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const tokens = @import("../../ast/tokens.zig");
const testing = @import("../../testing.zig");
const matchBrace = tokens.matchBrace;
const skipNestedFn = tokens.skipNestedFn;
const returnsType = tokens.returnsType;
const bodyOf = tokens.bodyOf;

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;

const R = "tagged-union-payload-early-exit";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .tagged_union_payload_early_exit)) return;
    _ = cache;

    var node_idx: u32 = 1;
    while (node_idx < tree.nodes.len) : (node_idx += 1) {
        const node: Ast.Node.Index = @enumFromInt(node_idx);
        if (tree.nodeTag(node) != .fn_decl) continue;
        if (returnsType(tree, node)) continue;
        const body = bodyOf(tree, node) orelse continue;
        try checkBody(gpa, tree, body, problems);
    }
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
    while (t + 4 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }

        // RHS must start with `= .{ .<Tag> =`
        if (tags[t] != .equal) continue;
        if (t + 4 > last) continue;
        if (tags[t + 1] != .period) continue;
        if (tags[t + 2] != .l_brace) continue;
        if (tags[t + 3] != .period) continue;
        if (tags[t + 4] != .identifier) continue;

        // Must be a SINGLE-field literal (tagged union variant, not a plain struct).
        if (literalHasTopLevelComma(tags, t + 1, last)) continue;

        // Verify the `=` is an assignment to an existing location, not a
        // `const`/`var` declaration.  Walk back from t-1 across the LHS path.
        if (t == 0) continue;
        var lhs_end: Ast.TokenIndex = t;
        lhs_end -= 1;
        if (tags[lhs_end] != .identifier) continue;
        var lhs_start: Ast.TokenIndex = lhs_end;
        while (lhs_start >= 2 and tags[lhs_start - 1] == .period and tags[lhs_start - 2] == .identifier) {
            lhs_start -= 2;
        }
        // The token before the LHS path must be a statement boundary.
        if (lhs_start > first) {
            const prev = tags[lhs_start - 1];
            const ok = prev == .semicolon or prev == .l_brace or
                prev == .r_brace or prev == .keyword_return or
                prev == .equal_angle_bracket_right or prev == .pipe;
            if (!ok) continue;
        }

        // Find the matching `}` of the outer literal.
        const rbrace = matchBrace(tags, t + 2, last) orelse continue;

        // Scan inside `.{ ... }` for `keyword_try`; fire at the first one.
        var u: Ast.TokenIndex = t + 3;
        while (u < rbrace) : (u += 1) {
            if (tags[u] == .keyword_try) {
                try report(gpa, problems, tree, u);
                break;
            }
        }
        t = rbrace;
    }
}

/// True iff the anonymous literal at `period_tok` (`.` followed by `{`)
/// has MORE THAN ONE top-level field — `.{ .a = …, .b = … }`.
fn literalHasTopLevelComma(
    tags: []const std.zig.Token.Tag,
    period_tok: Ast.TokenIndex,
    last: Ast.TokenIndex,
) bool {
    if (period_tok + 1 > last) return false;
    if (tags[period_tok + 1] != .l_brace) return false;
    const rbrace = matchBrace(tags, period_tok + 1, last) orelse return false;
    var paren: u32 = 0;
    var brace: u32 = 0;
    var bracket: u32 = 0;
    var fields: u32 = 0;
    var t: Ast.TokenIndex = period_tok + 2;
    while (t + 2 < rbrace) : (t += 1) {
        switch (tags[t]) {
            .l_paren => paren += 1,
            .r_paren => if (paren > 0) {
                paren -= 1;
            },
            .l_brace => brace += 1,
            .r_brace => if (brace > 0) {
                brace -= 1;
            },
            .l_bracket => bracket += 1,
            .r_bracket => if (bracket > 0) {
                bracket -= 1;
            },
            .period => if (paren == 0 and brace == 0 and bracket == 0) {
                if (tags[t + 1] == .identifier and tags[t + 2] == .equal) {
                    fields += 1;
                    if (fields > 1) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    try_tok: Ast.TokenIndex,
) !void {
    const msg = try gpa.dupe(u8, "`try` inside single-field union literal assignment — if the error propagates, the tag is written but the payload is left from the previous variant; hoist the `try` before the literal");
    errdefer gpa.free(msg);

    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, try_tok),
        .end = Pos.fromTokenEnd(tree, try_tok),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "tagged-union-payload-early-exit: try in single-field literal fires" {
    try testing.expectFires(check, R,
        \\const std = @import("std");
        \\const Self = struct {
        \\    state: union(enum) { ok: u32, err: u32 },
        \\    pub fn run(self: *Self) !void {
        \\        self.state = .{ .err = try computeErr() };
        \\    }
        \\};
        \\fn computeErr() !u32 { return 0; }
        \\
    );
}

test "tagged-union-payload-early-exit: no try does not fire" {
    try testing.expectNoFire(check,
        \\const Self = struct {
        \\    state: union(enum) { ok: u32, err: u32 },
        \\    pub fn run(self: *Self) void {
        \\        self.state = .{ .err = computeErr() };
        \\    }
        \\};
        \\fn computeErr() u32 { return 0; }
        \\
    );
}

test "tagged-union-payload-early-exit: const declaration with try does not fire" {
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\pub fn run() !void {
        \\    const x = .{ .err = try f() };
        \\    _ = x;
        \\}
        \\fn f() !u32 { return 0; }
        \\
    );
}

test "tagged-union-payload-early-exit: multi-field literal with try does not fire" {
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\const Self = struct {
        \\    state: struct { a: u32, b: u32 },
        \\    pub fn run(self: *Self) !void {
        \\        self.state = .{ .a = 1, .b = try f() };
        \\    }
        \\};
        \\fn f() !u32 { return 0; }
        \\
    );
}
