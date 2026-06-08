//! Detects `@alignCast(x.?)` — combining a forced optional unwrap with an
//! alignment assertion inside the same `@alignCast` call.  If `x` is null the
//! forced `.?` panics; if non-null the subsequent alignment check may also
//! panic on unaligned input.  The correct form is to use a non-optional type
//! for the pointer, or to guard with `orelse` before casting.
//!
//! Real-world instance:
//!   - tigerbeetle/tigerbeetle#3717 (io: even_listen):
//!     `@ptrCast(@alignCast(ctx.?))` — the nullable context was forced-unwrapped
//!     inside the align-cast; both the null-deref and the misalign checks were
//!     implicit.  Fix: changed all `?*anyopaque` context parameters to
//!     `*anyopaque`, eliminating the `.?` at every dereference site.
//!
//! Detection (Tier 1, flat token walk):
//!   Pattern: `builtin("@alignCast") l_paren identifier period question_mark r_paren`
//!   — 6 tokens.  Fire at the `@alignCast` builtin token.

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");
const tokens = @import("../../ast/tokens.zig");
const testing = @import("../../testing.zig");

const skipNestedFn = tokens.skipNestedFn;

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "aligncast-on-optional-unwrap";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .aligncast_on_optional_unwrap)) return;
    try tokens.forEachFnCached(gpa, tree, cache, problems, checkBody);
}

fn checkBody(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    proto: Ast.full.FnProto,
    body: Ast.Node.Index,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    _ = cache;
    const tags = tree.tokens.items(.tag);
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    if (first + 5 > last) return;

    var t: Ast.TokenIndex = first;
    while (t + 5 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }
        // Pattern: @alignCast ( identifier . ? )
        if (tags[t] != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t), "@alignCast")) continue;
        if (tags[t + 1] != .l_paren) continue;
        if (tags[t + 2] != .identifier) continue;
        if (tags[t + 3] != .period) continue;
        if (tags[t + 4] != .question_mark) continue;
        if (tags[t + 5] != .r_paren) continue;

        // Suppress the C-callback userdata-recovery idiom: when the unwrapped
        // operand is a `?*anyopaque` parameter, the framework invokes the
        // callback with the non-null pointer the caller registered, so
        // `@ptrCast(@alignCast(ctx.?))` is the standard (contractually safe)
        // way to recover the typed `self`.  Genuinely-nullable typed optionals
        // (`?*Foo` locals/params from fallible lookups) still fire.
        if (paramIsOptAnyopaque(tree, proto, tree.tokenSlice(t + 2))) continue;

        try report(gpa, problems, tree, t);
    }
}

/// True iff `name` is a parameter of `proto` whose type is `?*anyopaque` or
/// `?*const anyopaque` — the opaque callback-context type.
fn paramIsOptAnyopaque(tree: *const Ast, proto: Ast.full.FnProto, name: []const u8) bool {
    const tags = tree.tokens.items(.tag);
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const nt = param.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(nt), name)) continue;
        const te = param.type_expr orelse return false;
        const ft = tree.firstToken(te);
        const lt = tree.lastToken(te);
        // `?` … `*` … `anyopaque`
        if (tags[ft] != .question_mark) return false;
        if (tags[lt] != .identifier or !std.mem.eql(u8, tree.tokenSlice(lt), "anyopaque")) return false;
        var k = ft;
        while (k <= lt) : (k += 1) if (tags[k] == .asterisk) return true;
        return false;
    }
    return false;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    aligncast_tok: Ast.TokenIndex,
) !void {
    const name = tree.tokenSlice(aligncast_tok + 2);
    const msg = try std.fmt.allocPrint(
        gpa,
        "`@alignCast({s}.?)` — the forced `.?` panics when `{s}` is null and the alignment assertion may also panic on unaligned data; use a non-optional type for the pointer, or guard with `orelse` before casting",
        .{ name, name },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, aligncast_tok),
        .end = Pos.fromTokenEnd(tree, aligncast_tok + 5),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "aligncast-on-optional-unwrap: ?*anyopaque callback ctx idiom does not fire" {
    // The C-callback userdata-recovery idiom: the framework passes the
    // registered non-null pointer, so `@alignCast(ctx.?)` is contractually safe.
    try testing.expectNoFire(check,
        \\fn dispatchCallback(ctx: ?*anyopaque) void {
        \\    const self: *Handler = @ptrCast(@alignCast(ctx.?));
        \\    self.handle();
        \\}
        \\
    );
}

test "aligncast-on-optional-unwrap: ?*const anyopaque callback ctx idiom does not fire" {
    try testing.expectNoFire(check,
        \\fn dispatchCallback(data: ?*const anyopaque) void {
        \\    const self: *const Handler = @ptrCast(@alignCast(data.?));
        \\    self.handle();
        \\}
        \\
    );
}

test "aligncast-on-optional-unwrap: genuinely-nullable typed optional param still fires" {
    try testing.expectFires(check, R,
        \\fn use(p: ?*Foo) void {
        \\    const f: *Foo = @alignCast(p.?);
        \\    f.run();
        \\}
        \\
    );
}

test "aligncast-on-optional-unwrap: non-optional does not fire" {
    try testing.expectNoFire(check,
        \\fn dispatchCallback(ctx: *anyopaque) void {
        \\    const self: *Handler = @ptrCast(@alignCast(ctx));
        \\    self.handle();
        \\}
        \\
    );
}

test "aligncast-on-optional-unwrap: orelse guard does not fire" {
    try testing.expectNoFire(check,
        \\fn dispatchCallback(ctx: ?*anyopaque) void {
        \\    const self: *Handler = @ptrCast(@alignCast(ctx orelse return));
        \\    self.handle();
        \\}
        \\
    );
}

test "aligncast-on-optional-unwrap: standalone .? not in alignCast does not fire" {
    try testing.expectNoFire(check,
        \\fn getHandler(opt: ?*Handler) *Handler {
        \\    return opt.?;
        \\}
        \\
    );
}
