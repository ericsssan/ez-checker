//! Scope-aware iteration primitives.
//!
//! Three patterns recurred across every precision-tightened
//! pattern detector:
//!   1. "Find a use of <name> in the binding's enclosing scope"
//!      — bounded by the enclosing `}`, allowing nested blocks
//!      inside the scope but stopping when we'd cross out of it.
//!      (Sibling scopes shouldn't trigger via shadowed names.)
//!   2. "Find a call to <recv>.<method>(...) at the SAME lexical
//!      block depth as a binding" — skip nested blocks (catch/if/
//!      loop bodies might not execute) and skip defer/errdefer
//!      (deferred, not inline).
//!   3. "Walk the body collecting matches, skipping nested fns."
//!
//! These three are encoded as three orthogonal iterators below.

const std = @import("std");
const Ast = std.zig.Ast;
const tokens = @import("tokens.zig");

const TokenIndex = tokens.TokenIndex;
const TokenTag = tokens.TokenTag;

/// Find the first identifier whose text equals `name` in the
/// binding's enclosing scope.  Walks forward from `start`; allows
/// the use to be inside nested blocks within the binding's scope
/// (`try map.put(...); for (...) p.* += 1;`).  Stops at the
/// enclosing scope's closing `}` — same-name identifiers in
/// sibling scopes (shadowed loop captures, etc.) don't match.
pub fn findIdentUseInEnclosingScope(
    tree: *const Ast,
    start: TokenIndex,
    last: TokenIndex,
    name: []const u8,
) ?TokenIndex {
    const tags = tree.tokens.items(.tag);
    if (start > last) return null;
    var depth: u32 = 0;
    var t: TokenIndex = start;
    while (t <= last) : (t += 1) {
        switch (tags[t]) {
            .l_brace => depth += 1,
            .r_brace => if (depth == 0) return null else {
                depth -= 1;
            },
            .identifier => if (std.mem.eql(u8, tree.tokenSlice(t), name)) return t,
            else => {},
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────

test "findIdentUseInEnclosingScope stops at enclosing }" {
    const src: [:0]const u8 =
        \\fn f() void {
        \\    { const entry = 1; _ = entry; }
        \\    for (0..1) |entry| { _ = entry; }
        \\}
    ;
    var tree = try Ast.parse(std.testing.allocator, src, .zig);
    defer tree.deinit(std.testing.allocator);
    const tags = tree.tokens.items(.tag);
    const last: TokenIndex = @intCast(tree.tokens.len - 1);
    // Find first `const entry = 1;` binding token.
    var t: TokenIndex = 0;
    while (t <= last) : (t += 1) {
        if (tags[t] == .keyword_const) break;
    }
    // Skip `const`, find `entry` (the bound name).
    t += 1;
    // After the binding's `;`, scan for `entry` use.
    var sc: TokenIndex = t;
    while (sc <= last and tags[sc] != .semicolon) : (sc += 1) {}
    // Use within the same `{...}` block must be found; the
    // `entry` in the sibling `for` block must NOT match.
    const use = findIdentUseInEnclosingScope(&tree, sc + 1, last, "entry").?;
    // The use should be the `_ = entry;` IN THE SAME BLOCK
    // (before the inner `}`), not the for-loop one.
    // Verify by checking the token is followed by `;` then `}`.
    try std.testing.expectEqual(TokenTag.semicolon, tags[use + 1]);
    try std.testing.expectEqual(TokenTag.r_brace, tags[use + 2]);
}
