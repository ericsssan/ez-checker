//! Per-rule decision trace.
//!
//! Rules sprinkle `trace.note(...)` calls at decision points
//! (matched a pattern, rejected for X reason, advanced past Y).
//! By default the calls are no-ops.  When the user runs zbc with
//! `--trace=<rule-id>` (or `--trace=*` for all), the matching
//! rule's notes print to stderr with file:line:col context.
//!
//! Purpose: debugging false positives and false negatives without
//! resorting to printf-recompile cycles.  When a rule misses a
//! site or fires on something it shouldn't, the trace shows what
//! the rule actually saw vs. what it skipped.
//!
//! Performance: one compare-and-branch per call when no trace is
//! active.  No allocation on the no-op path.  The `std.debug.print`
//! cost is only paid for actively traced rules.
//!
//! Example usage in a rule:
//!
//!     const trace = @import(\"../trace.zig\");
//!     const R = \"fd-write-after-close\";
//!
//!     trace.note(R, tree, t, \"matched createFile() at binding\");
//!     trace.skip(R, tree, t, \"close is inside defer\");
//!     trace.match(R, tree, use_tok, \"use after close\");
//!
//! Run: `zbc --trace=fd-write-after-close path/to/file.zig`

const std = @import("std");
const Ast = std.zig.Ast;

const TokenIndex = std.zig.Ast.TokenIndex;

/// If set, only this rule's traces print.  Set via `--trace=<id>`.
pub var active_rule: ?[]const u8 = null;

/// If true, traces from ALL rules print.  Set via `--trace=*`.
pub var all_rules: bool = false;

/// Current file being analysed — included in trace output so corpus
/// sweeps identify which file each event came from.  Thread-local so
/// concurrent workers don't clobber each other's context.
pub threadlocal var current_file: ?[]const u8 = null;

/// Set before analysing a file; cleared on `reset()`.
pub fn setFile(path: []const u8) void {
    current_file = path;
}

/// True iff the rule's traces should print right now.  Rules can
/// guard expensive trace-construction work with this:
///
///     if (trace.isActive(R)) {
///         const label = try std.fmt.allocPrint(...);
///         defer gpa.free(label);
///         trace.note(R, tree, t, label);
///     }
fn isActive(rule_id: []const u8) bool {
    if (all_rules) return true;
    const want = active_rule orelse return false;
    return std.mem.eql(u8, want, rule_id);
}

/// Generic trace note — neutral verb.  Use `match` for "rule
/// matched here" and `skip` for "rule rejected here, reason: ...".
pub fn note(rule_id: []const u8, tree: *const Ast, tok: TokenIndex, msg: []const u8) void {
    if (!isActive(rule_id)) return;
    printNote(rule_id, "note", tree, tok, msg);
}

/// "The rule matched / fired here."  Use at the point of decision
/// where the rule decides to report a problem.
pub fn match(rule_id: []const u8, tree: *const Ast, tok: TokenIndex, msg: []const u8) void {
    if (!isActive(rule_id)) return;
    printNote(rule_id, "match", tree, tok, msg);
}

/// "The rule considered this site but rejected it.  Reason: ..."
/// Use at every early-exit point so the user can see why an
/// expected site wasn't reported.
pub fn skip(rule_id: []const u8, tree: *const Ast, tok: TokenIndex, reason: []const u8) void {
    if (!isActive(rule_id)) return;
    printNote(rule_id, "skip", tree, tok, reason);
}

/// "Rule entered a new analysis scope (a fn body, a struct decl)."
/// Useful for following the rule's traversal at a high level.
pub fn enter(rule_id: []const u8, tree: *const Ast, tok: TokenIndex, what: []const u8) void {
    if (!isActive(rule_id)) return;
    printNote(rule_id, "enter", tree, tok, what);
}

fn printNote(
    rule_id: []const u8,
    kind: []const u8,
    tree: *const Ast,
    tok: TokenIndex,
    msg: []const u8,
) void {
    const file = current_file orelse "<unknown>";
    if (tok >= tree.tokens.len) {
        std.debug.print("[trace:{s}] {s}: {s}:<oob-token> {s}\n", .{ rule_id, kind, file, msg });
        return;
    }
    const loc = tree.tokenLocation(0, tok);
    std.debug.print(
        "[trace:{s}] {s} @ {s}:{d}:{d}: {s}\n",
        .{ rule_id, kind, file, loc.line + 1, loc.column + 1, msg },
    );
}

/// Reset trace flags — useful in tests so trace state doesn't leak.
pub fn reset() void {
    active_rule = null;
    all_rules = false;
    current_file = null;
}

// ── Tests ──────────────────────────────────────────────────

test "isActive: inactive by default" {
    reset();
    try std.testing.expect(!isActive("any-rule"));
}

test "isActive: active for the named rule only" {
    reset();
    active_rule = "fd-write-after-close";
    try std.testing.expect(isActive("fd-write-after-close"));
    try std.testing.expect(!isActive("other-rule"));
    reset();
}

test "isActive: all_rules wins" {
    reset();
    all_rules = true;
    try std.testing.expect(isActive("any-rule"));
    try std.testing.expect(isActive("yet-another"));
    reset();
}
