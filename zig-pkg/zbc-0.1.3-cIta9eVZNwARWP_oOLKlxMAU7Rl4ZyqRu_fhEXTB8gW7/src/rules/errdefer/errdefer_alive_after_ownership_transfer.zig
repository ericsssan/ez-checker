//! Detects an `errdefer X.deinit()` (or .deref/.free/.release) that
//! remains armed after an ownership-taking constructor call receives `X`
//! as an argument, followed by a subsequent `try` that triggers the
//! errdefer — double-freeing `X` while the constructor already owns it.
//!
//! Pattern:
//!   const path = try PathLike.fromJS(global, &args);
//!   errdefer path.deinit();                    // ← armed
//!   const blob = try constructS3File(global, path); // ← ownership taken
//!   try doMoreWork();                          // ← errdefer fires → double-free
//!
//! Fix: after the constructor call that takes ownership, disarm the errdefer
//! by resetting `X` to a safe sentinel:
//!   const blob = try constructS3File(global, path);
//!   path = .{};  // or path = undefined;   ← disarms the errdefer
//!   try doMoreWork();
//!
//! Real-world shape: oven-sh/bun#28495, #28592, #29081, #29643, #29656,
//! #30169, #30437, #30465 — a cluster of 8 PRs all fixing the same
//! ownership-transfer + live-errdefer double-free in bun's S3 / node_fs /
//! CSS parsers.
//!
//! Detection (Tier 1, token walk per fn body):
//!   1. Scan for `keyword_errdefer identifier(X) period identifier(CLEANUP)
//!      l_paren r_paren` where CLEANUP ∈ {deinit, deref, free, release,
//!      close, destroy}.  Record (X, errdefer_tok).
//!   2. For each armed X, scan forward for a call where:
//!      a. The callee name starts with "construct", "create", OR equals
//!         "init", "make", "build", "fromOwned", "toOwned".
//!      b. X appears as a direct argument (identifier X appears between
//!         the call's l_paren and r_paren at depth 0).
//!      Record the close-paren of that call as `transfer_end`.
//!   3. Scan forward from `transfer_end` for `keyword_try` before
//!      `identifier(X) equal` (disarming assignment).
//!   4. Fire at the `keyword_try` token (step 3).

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
const R = "errdefer-alive-after-ownership-transfer";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .errdefer_alive_after_ownership_transfer)) return;
    _ = cache;
    try tokens.forEachFnBody(gpa, tree, problems, checkBody);
}

const Armed = struct {
    x_name: []const u8,
    errdefer_tok: Ast.TokenIndex,
    /// First token AFTER the errdefer's closing `)`.
    scan_from: Ast.TokenIndex,
};

fn checkBody(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body: Ast.Node.Index,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    const tags = tree.tokens.items(.tag);
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);

    // Collect all errdefer X.cleanup() registrations.
    var armed: std.ArrayListUnmanaged(Armed) = .empty;
    defer armed.deinit(gpa);

    var t: Ast.TokenIndex = first;
    while (t + 5 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }
        if (tags[t] != .keyword_errdefer) continue;
        if (tags[t + 1] != .identifier) continue;
        if (tags[t + 2] != .period) continue;
        if (tags[t + 3] != .identifier) continue;
        if (!isCleanupName(tree.tokenSlice(t + 3))) continue;
        if (tags[t + 4] != .l_paren) continue;
        if (tags[t + 5] != .r_paren) continue;

        try armed.append(gpa, .{
            .x_name = tree.tokenSlice(t + 1),
            .errdefer_tok = t,
            .scan_from = t + 6,
        });
    }

    if (armed.items.len == 0) return;

    for (armed.items) |a| {
        if (a.scan_from > last) continue;

        // Find an ownership-taking call that receives X as an arg.
        const transfer_end = findOwnershipCall(tree, tags, a.scan_from, last, a.x_name) orelse continue;

        // Scan from transfer_end forward for a `try` before `X = `.
        const danger_try = findTryBeforeDisarm(tree, tags, transfer_end, last, a.x_name) orelse continue;

        try report(gpa, problems, tree, danger_try, a.x_name);
    }
}

fn isCleanupName(name: []const u8) bool {
    return std.mem.eql(u8, name, "deinit") or
        std.mem.eql(u8, name, "deref") or
        std.mem.eql(u8, name, "free") or
        std.mem.eql(u8, name, "release") or
        std.mem.eql(u8, name, "close") or
        std.mem.eql(u8, name, "destroy");
}

/// Returns true iff the callee name indicates ownership transfer.
fn isOwnershipName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "construct")) return true;
    if (std.mem.startsWith(u8, name, "create")) return true;
    if (std.mem.eql(u8, name, "init")) return true;
    if (std.mem.eql(u8, name, "make")) return true;
    if (std.mem.eql(u8, name, "build")) return true;
    if (std.mem.eql(u8, name, "fromOwned")) return true;
    if (std.mem.eql(u8, name, "toOwned")) return true;
    if (std.mem.startsWith(u8, name, "from") and name.len > 4) return true;
    return false;
}

/// Scans [start, last] for an ownership-taking call that passes `x_name`
/// as a direct argument.  Returns the token just after the call's `)`.
fn findOwnershipCall(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    last: Ast.TokenIndex,
    x_name: []const u8,
) ?Ast.TokenIndex {
    var t: Ast.TokenIndex = start;
    while (t + 1 <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }

        // Look for `identifier(ownership_name) l_paren`
        if (tags[t] != .identifier) continue;
        if (t + 1 > last or tags[t + 1] != .l_paren) continue;
        if (!isOwnershipName(tree.tokenSlice(t))) continue;

        // Scan the argument list for x_name as a direct argument.
        const open = t + 1;
        var depth: u32 = 1;
        var found_x = false;
        var u: Ast.TokenIndex = open + 1;
        while (u <= last and depth > 0) : (u += 1) {
            switch (tags[u]) {
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                .identifier => {
                    if (depth == 1 and std.mem.eql(u8, tree.tokenSlice(u), x_name)) {
                        // Reject `x_name.field` / `x_name.method()` — x is
                        // used as a receiver, not passed as a direct argument.
                        const next = u + 1;
                        if (next <= last and tags[next] == .period) break;
                        found_x = true;
                    }
                },
                else => {},
            }
        }
        if (found_x) return u; // u is now after the `)`
    }
    return null;
}

/// Scans [start, last] for `keyword_try` before `identifier(x_name) equal`.
/// Returns the `keyword_try` token index, or null if x_name is disarmed first.
fn findTryBeforeDisarm(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    last: Ast.TokenIndex,
    x_name: []const u8,
) ?Ast.TokenIndex {
    var t: Ast.TokenIndex = start;
    while (t <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = skipNestedFn(tags, t, last);
            continue;
        }

        // Disarming assignment: x_name = ...
        if (tags[t] == .identifier and
            std.mem.eql(u8, tree.tokenSlice(t), x_name) and
            t + 1 <= last and tags[t + 1] == .equal)
            return null; // disarmed

        if (tags[t] == .keyword_try) return t;
    }
    return null;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    try_tok: Ast.TokenIndex,
    x_name: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`errdefer {s}.deinit()` is still armed after a constructor call that took ownership of `{s}` — if this `try` propagates an error, the errdefer fires and double-frees `{s}`; reset `{s} = .{{}}` (or the appropriate inert sentinel) immediately after the ownership-taking call to disarm the errdefer",
        .{ x_name, x_name, x_name, x_name },
    );
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

test "errdefer-alive-after-ownership-transfer: construct fires" {
    try testing.expectFires(check, R,
        \\fn buildWidget(global: *JSGlobal, args: *Args) !JSValue {
        \\    const path = try PathLike.fromJS(global, args);
        \\    errdefer path.deinit();
        \\    const blob = try constructWidget(global, path);
        \\    _ = blob;
        \\    try doMoreWork();
        \\    return .undefined;
        \\}
        \\
    );
}

test "errdefer-alive-after-ownership-transfer: disarmed path does not fire" {
    try testing.expectNoFire(check,
        \\fn buildWidget(global: *JSGlobal, args: *Args) !JSValue {
        \\    const path = try PathLike.fromJS(global, args);
        \\    errdefer path.deinit();
        \\    const blob = try constructWidget(global, path);
        \\    path = .{};   // ← disarmed
        \\    try doMoreWork();
        \\    return .undefined;
        \\}
        \\
    );
}

test "errdefer-alive-after-ownership-transfer: no subsequent try does not fire" {
    try testing.expectNoFire(check,
        \\fn buildWidget(global: *JSGlobal, args: *Args) !JSValue {
        \\    const path = try PathLike.fromJS(global, args);
        \\    errdefer path.deinit();
        \\    const blob = try constructWidget(global, path);
        \\    _ = blob;
        \\    return .undefined;
        \\}
        \\
    );
}

test "errdefer-alive-after-ownership-transfer: non-ownership call does not fire" {
    try testing.expectNoFire(check,
        \\fn render(global: *JSGlobal, args: *Args) !JSValue {
        \\    const path = try PathLike.fromJS(global, args);
        \\    errdefer path.deinit();
        \\    const s = try display(global, path);
        \\    try doMoreWork();
        \\    return s;
        \\}
        \\
    );
}

test "errdefer-alive-after-ownership-transfer: x.method() receiver is not ownership transfer" {
    // `arena.allocator()` passes the allocator interface, not arena itself.
    // The errdefer on `arena` should not fire.
    try testing.expectNoFire(check,
        \\fn init(io: Io, gpa: Allocator) !Self {
        \\    var arena = std.heap.ArenaAllocator.init(gpa);
        \\    errdefer arena.deinit();
        \\    const state = try Response.State.init(arena.allocator(), &config);
        \\    try doMoreWork();
        \\    return .{ .arena = arena, .state = state };
        \\}
        \\
    );
}
