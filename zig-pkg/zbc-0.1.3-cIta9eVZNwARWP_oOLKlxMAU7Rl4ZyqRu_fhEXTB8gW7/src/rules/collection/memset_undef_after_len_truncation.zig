//! Memset-undef-after-len-truncation detector — `self.items.len =
//! NEW; @memset(self.items[NEW..], undefined);` (or `= 0; @memset(
//! self.items, undefined)`) — the memset slices the ALREADY-
//! TRUNCATED items, so the range is empty and the memset is a no-op.
//! The freed-but-retained capacity keeps its old bytes, defeating
//! Zig's `undefined` use-after-shrink safety detection.
//!
//! Real-world: ziglang/zig#25810 + #25832 fix this in both
//! `ArrayListAligned` and `ArrayListAlignedManaged`'s
//! `shrinkRetainingCapacity` / `clearRetainingCapacity`.
//!
//! Rewritten via the query DSL: two patterns + same-scope find.

const std = @import("std");
const Ast = std.zig.Ast;

const tokens = @import("../../ast/tokens.zig");
const query = @import("../../ast/token_query.zig");
const problem = @import("../../problem.zig");
const testing = @import("../../testing.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const Atom = query.Atom;
const R = "memset-undef-after-len-truncation";

// Pattern: `$X.$F.len = ...;`
//   slot 0 — receiver name (X)
//   slot 1 — field name (F)
const len_truncation = &[_]Atom{
    .{ .capture = 0 },
    .{ .tok = .period },
    .{ .capture = 1 },
    .{ .tok = .period },
    .{ .text = "len" },
    .{ .tok = .equal },
};

// Pattern: `@memset($X.$F...)` — the first arg starts with `$X.$F`.
const memset_on_slice = &[_]Atom{
    .{ .builtin = "@memset" },
    .{ .tok = .l_paren },
    .{ .ref = 0 },
    .{ .tok = .period },
    .{ .ref = 1 },
};

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(problem.Problem),
) !void {
    if (!config_mod.isEnabled(config, .memset_undef_after_len_truncation)) return;
    _ = cache;
    try tokens.forEachFnBody(gpa, tree, problems, checkBody);
}

fn checkBody(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body: Ast.Node.Index,
    problems: *std.ArrayListUnmanaged(problem.Problem),
) !void {
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);

    const truncations = try query.findAllInBody(gpa, tree, len_truncation, first, last);
    defer gpa.free(truncations);

    for (truncations) |t| {
        const ms = query.findInSameScope(tree, memset_on_slice, t.end + 1, last, &t) orelse continue;
        try report(gpa, problems, tree, ms.start, t.captures[0].?, t.captures[1].?);
    }
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(problem.Problem),
    tree: *const Ast,
    memset_tok: query.TokenIndex,
    x_tok: query.TokenIndex,
    field_tok: query.TokenIndex,
) !void {
    const x_name = tree.tokenSlice(x_tok);
    const field_name = tree.tokenSlice(field_tok);
    const msg = try std.fmt.allocPrint(
        gpa,
        "`@memset({s}.{s}[...]...)` follows `{s}.{s}.len = ...;` — the memset slices the ALREADY-TRUNCATED items so the range is empty and the memset is a no-op.  The freed-but-retained capacity keeps its old bytes, defeating Zig's `undefined` use-after-shrink safety.  Swap the order: `@memset(...)` BEFORE the `.len = ...` truncation",
        .{ x_name, field_name, x_name, field_name },
    );
    errdefer gpa.free(msg);

    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = problem.Pos.fromTokenStart(tree, memset_tok),
        .end = problem.Pos.fromTokenEnd(tree, memset_tok),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "shrink-then-memset (canonical bug) fires" {
    try testing.expectFires(check, R,
        \\const T = struct {
        \\    items: []u8,
        \\    pub fn shrink(self: *T, new_len: usize) void {
        \\        self.items.len = new_len;
        \\        @memset(self.items[new_len..], undefined);
        \\    }
        \\};
    );
}

test "clear-then-memset-all (clearRetainingCapacity bug) fires" {
    try testing.expectFires(check, R,
        \\const T = struct {
        \\    items: []u8,
        \\    pub fn clear(self: *T) void {
        \\        self.items.len = 0;
        \\        @memset(self.items, undefined);
        \\    }
        \\};
    );
}

test "memset BEFORE truncation (correct order) doesn't fire" {
    try testing.expectNoFire(check,
        \\const T = struct {
        \\    items: []u8,
        \\    pub fn shrinkFixed(self: *T, new_len: usize) void {
        \\        @memset(self.items[new_len..], undefined);
        \\        self.items.len = new_len;
        \\    }
        \\};
    );
}

test "memset on a different field doesn't fire" {
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\const T = struct {
        \\    items: []u8,
        \\    other: []u8,
        \\    pub fn shrink(self: *T, new_len: usize) void {
        \\        self.items.len = new_len;
        \\        @memset(self.other, undefined);
        \\    }
        \\};
    );
}
