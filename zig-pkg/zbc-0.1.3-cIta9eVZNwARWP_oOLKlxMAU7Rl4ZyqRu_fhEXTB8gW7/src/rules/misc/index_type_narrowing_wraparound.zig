//! Detects loop-index or buffer-size variables declared with a narrow
//! signed integer type (any `iN` with `N < 64`) whose initialiser comes from
//! a `.len` expression, or that are subsequently used as an array index.
//!
//! Real-world shape: oven-sh/bun#31129 (url_path), oven-sh/bun#31339
//! (SQL result) — a loop counter typed `i16` is initialised from
//! `decoded_pathname.len - 1`.  When the path is longer than 32 767
//! bytes the `@intCast` wraps and the counter starts negative, so the
//! loop body never executes (or runs backward).
//!
//! Detection (purely syntactic, per-fn token walk):
//!   1. Find `var NAME : TYPE = EXPR` where TYPE is a signed `iN`, `N < 64`.
//!      Token pattern:
//!        t+0: `.keyword_var`
//!        t+1: `.identifier`   (NAME)
//!        t+2: `.colon`
//!        t+3: `.identifier`   with text `iN` where 1 <= N < 64
//!        t+4: `.equal`
//!   2. Fire when the initialiser EXPR (tokens after `=` up to `;`)
//!      contains `.len` — i.e. a `period` followed immediately by an
//!      identifier with text `"len"`.
//!   3. OR fire when NAME appears as an array subscript anywhere in
//!      the same fn body: find `[ NAME` (l_bracket followed by an
//!      identifier whose text is NAME).
//!   4. Fire at the type-annotation token (t+3).

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const tokens = @import("../../ast/tokens.zig");
const testing = @import("../../testing.zig");

const findStmtSemicolon = tokens.findStmtSemicolon;
const skipFnDecl = tokens.skipFnDecl;

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "index-type-narrowing-wraparound";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .index_type_narrowing_wraparound)) return;
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
    while (t + 4 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipFnDecl(tags, t, last);
            continue;
        }

        // Pattern: `var NAME : TYPE = …`
        //   t+0: keyword_var
        //   t+1: identifier (NAME)
        //   t+2: colon
        //   t+3: identifier with text in {"i8","i16","i32"}
        //   t+4: equal
        if (tags[t] != .keyword_var) continue;
        if (tags[t + 1] != .identifier) continue;
        if (tags[t + 2] != .colon) continue;
        if (tags[t + 3] != .identifier) continue;
        if (tags[t + 4] != .equal) continue;

        const type_text = tree.tokenSlice(t + 3);
        if (!isNarrowSignedType(type_text)) continue;

        const name = tree.tokenSlice(t + 1);

        // Find the end of the initialiser statement.
        const sc = findStmtSemicolon(tags, t + 4, last) orelse continue;

        // Condition 1: initialiser contains `.len`.
        if (exprContainsLen(tree, t + 5, sc -| 1)) {
            // Suppress when the `.len` is clamped to the target type's max via
            // `@min(.len, maxInt(TYPE))` or `@min(.len, max_<TYPE>)`.  The clamp
            // guarantees the value fits TYPE, so the `@intCast` cannot wrap.
            if (exprClampsToType(tree, tags, t + 5, sc -| 1, type_text)) continue;
            try report(gpa, problems, tree, t + 3, name, type_text);
            continue;
        }

        // Condition 2: NAME appears as array subscript `[ NAME` in
        // the rest of the fn body.
        if (nameUsedAsIndex(tree, tags, sc + 1, last, name)) {
            try report(gpa, problems, tree, t + 3, name, type_text);
        }
    }
}

/// True iff the initialiser range [start, end] clamps the value to fit
/// `type_text` via a `@min(...)` whose bound is the target type's maximum:
///   `@min(.., maxInt(TYPE))`   — `maxInt` `(` `TYPE` `)`
///   `@min(.., max_<TYPE>)`     — identifier literally "max_" ++ TYPE
/// Requires BOTH a `@min` builtin and a matching maxInt bound in range, so a
/// mismatched clamp (e.g. `@min(len, max_i32)` assigned to `i16`) still fires.
fn exprClampsToType(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
    type_text: []const u8,
) bool {
    if (start > end) return false;

    var has_min = false;
    var has_bound = false;
    var t: Ast.TokenIndex = start;
    while (t <= end) : (t += 1) {
        if (tags[t] == .builtin and std.mem.eql(u8, tree.tokenSlice(t), "@min")) {
            has_min = true;
            continue;
        }
        if (tags[t] == .identifier) {
            const s = tree.tokenSlice(t);
            // `maxInt(TYPE)` — identifier "maxInt" followed by `( TYPE )`.
            if (std.mem.eql(u8, s, "maxInt") and t + 2 <= end and
                tags[t + 1] == .l_paren and tags[t + 2] == .identifier and
                std.mem.eql(u8, tree.tokenSlice(t + 2), type_text))
            {
                has_bound = true;
                continue;
            }
            // `max_<TYPE>` constant, e.g. `max_i32` for an `i32` target.
            if (std.mem.startsWith(u8, s, "max_") and
                std.mem.eql(u8, s["max_".len..], type_text))
            {
                has_bound = true;
            }
        }
    }
    return has_min and has_bound;
}

/// True iff `s` is a SIGNED integer type narrower than the `usize` index
/// space — `i1` … `i63` — any of which can wrap when used to index a
/// collection larger than its maximum.  Generalises the former hardcoded
/// {i8,i16,i32} list to also cover i24/i48/etc.  `isize` (pointer-width) and
/// `i64`+ are excluded (they cannot be over-indexed in practice).
fn isNarrowSignedType(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'i') return false;
    const bits = std.fmt.parseInt(u16, s[1..], 10) catch return false;
    return bits >= 1 and bits < 64;
}

/// Max value for the narrow type `iN` — `2^(N-1) - 1` — used in the
/// diagnostic message.  Only called for types `isNarrowSignedType` accepted,
/// so `1 <= N < 64`.
fn maxValueForType(s: []const u8) i64 {
    const bits = std.fmt.parseInt(u16, s[1..], 10) catch return 0; // zbc-disable-line: slice-from-fixed-offset-without-len-check — only called for isNarrowSignedType; those are "iN" strings with len>=2
    if (bits == 0 or bits >= 64) return 0;
    const shift: u6 = @intCast(bits - 1);
    return (@as(i64, 1) << shift) - 1;
}

/// True iff the token range `[start, end]` contains `.len` —
/// a `period` token immediately followed by an `identifier` "len".
fn exprContainsLen(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex) bool {
    if (start > end) return false;
    const tags = tree.tokens.items(.tag);
    var t: Ast.TokenIndex = start;
    while (t + 1 <= end) : (t += 1) {
        if (tags[t] == .period and
            tags[t + 1] == .identifier and
            std.mem.eql(u8, tree.tokenSlice(t + 1), "len")) return true;
    }
    return false;
}

/// True iff `name` appears immediately after `[` in `[start, end]`
/// — i.e. the pattern `l_bracket identifier(name)`.
fn nameUsedAsIndex(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
    name: []const u8,
) bool {
    if (start > end) return false;
    var t: Ast.TokenIndex = start;
    while (t + 1 <= end) : (t += 1) {
        if (tags[t] == .l_bracket and
            tags[t + 1] == .identifier and
            std.mem.eql(u8, tree.tokenSlice(t + 1), name)) return true;
    }
    return false;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    type_tok: Ast.TokenIndex,
    name: []const u8,
    type_text: []const u8,
) !void {
    const max_val = maxValueForType(type_text);
    const msg = try std.fmt.allocPrint(
        gpa,
        "index variable `{s}` is typed `{s}` — if the indexed collection has more than {d} items, the index wraps around; use `usize` or a wider type",
        .{ name, type_text, max_val },
    );
    errdefer gpa.free(msg);

    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, type_tok),
        .end = Pos.fromTokenEnd(tree, type_tok),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "index-type-narrowing-wraparound: i16 init from .len fires" {
    try testing.expectFires(check, R,
        \\fn f(arr: []const u8) void {
        \\    var i: i16 = @intCast(arr.len) - 1;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: i16 used as array index fires" {
    try testing.expectFires(check, R,
        \\fn f(arr: []const u8) void {
        \\    var i: i16 = 0;
        \\    _ = arr[i];
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: i32 init from .len fires" {
    try testing.expectFires(check, R,
        \\fn f(arr: []const u8) void {
        \\    var j: i32 = arr.len - 1;
        \\    _ = j;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: i8 init from .len fires" {
    try testing.expectFires(check, R,
        \\fn f(arr: []const u8) void {
        \\    var k: i8 = @intCast(arr.len);
        \\    _ = k;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: i24 init from .len fires (generalized width)" {
    try testing.expectFires(check, R,
        \\fn f(arr: []const u8) void {
        \\    var i: i24 = @intCast(arr.len) - 1;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: isize does not fire" {
    try testing.expectNoFire(check,
        \\fn f(arr: []const u8) void {
        \\    var i: isize = @intCast(arr.len) - 1;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: u16 from .len does not fire" {
    try testing.expectNoFire(check,
        \\fn f(arr: []const u8) void {
        \\    var i: u16 = @intCast(arr.len) - 1;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: i64 from .len does not fire" {
    try testing.expectNoFire(check,
        \\fn f(arr: []const u8) void {
        \\    var i: i64 = arr.len - 1;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: const i16 does not fire" {
    try testing.expectNoFire(check,
        \\fn f() void {
        \\    const i: i16 = 0;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: i16 with no len and not used as index does not fire" {
    try testing.expectNoFire(check,
        \\fn f() void {
        \\    var i: i16 = 42;
        \\    _ = i;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: @min clamp with max_i32 const does not fire" {
    try testing.expectNoFire(check,
        \\const max_i32 = std.math.maxInt(i32);
        \\fn addr(buf: []u8) void {
        \\    var length: i32 = @intCast(@min(buf.len, max_i32));
        \\    _ = length;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: @min clamp with maxInt(i32) does not fire" {
    try testing.expectNoFire(check,
        \\fn addr(buf: []u8) void {
        \\    var length: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        \\    _ = length;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: mismatched clamp type still fires" {
    try testing.expectFires(check, R,
        \\const max_i32 = std.math.maxInt(i32);
        \\fn addr(buf: []u8) void {
        \\    var length: i16 = @intCast(@min(buf.len, max_i32));
        \\    _ = length;
        \\}
        \\
    );
}

test "index-type-narrowing-wraparound: subtraction without clamp still fires" {
    try testing.expectFires(check, R,
        \\fn f(decoded_pathname: []const u8) void {
        \\    var i: i16 = @as(i16, @intCast(decoded_pathname.len)) - 1;
        \\    _ = i;
        \\}
        \\
    );
}
