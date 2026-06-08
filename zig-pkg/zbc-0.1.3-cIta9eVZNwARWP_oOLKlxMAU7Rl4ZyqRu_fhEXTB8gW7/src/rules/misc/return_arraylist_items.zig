//! Detects `return identifier.items;` inside a function — returning the
//! `.items` slice of a local `ArrayList` directly leaks the backing
//! allocation: the caller receives a `[]T` slice but has no `ArrayList`
//! handle to call `.deinit()` on, so the capacity bytes are permanently
//! lost.  The correct form is `return list.toOwnedSlice()`, which transfers
//! ownership of exactly the used bytes to the caller.
//!
//! Real-world instance:
//!   - oven-sh/bun#23885 (toUTF8AllocWithType): the function built a local
//!     `var list = try std.ArrayList(u8).initCapacity(allocator, n)` and
//!     returned `list.items`.  The caller freed the returned slice via
//!     `allocator.free()`, which freed only `items.len` bytes; the extra
//!     capacity allocated by `initCapacity` leaked on every call.
//!     Fix: `return list.toOwnedSlice()`.
//!
//! Detection (Tier 1, flat token walk):
//!   Pattern: `keyword_return identifier period identifier("items") semicolon`
//!   — 5 tokens.  Fire at the `return` token.
//!   Suppresses `self`/`this` receivers (those access a struct field, not a
//!   local ArrayList).  `return list.toOwnedSlice()` does NOT match (ends
//!   with `l_paren` not `semicolon`).

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const testing = @import("../../testing.zig");

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "return-arraylist-items";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .return_arraylist_items)) return;
    _ = cache;

    const tags = tree.tokens.items(.tag);
    const last_tok: Ast.TokenIndex = @intCast(tree.tokens.len -| 1);

    var t: Ast.TokenIndex = 0;
    while (t + 4 <= last_tok) : (t += 1) {
        // Pattern: return identifier . items ;
        if (tags[t] != .keyword_return) continue;
        if (tags[t + 1] != .identifier) continue;
        if (tags[t + 2] != .period) continue;
        if (tags[t + 3] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(t + 3), "items")) continue;
        if (tags[t + 4] != .semicolon) continue;

        // Suppress self/this — those access a struct field, not a local ArrayList.
        const recv = tree.tokenSlice(t + 1);
        if (std.mem.eql(u8, recv, "self") or std.mem.eql(u8, recv, "this")) continue;

        // Suppress `assert(recv.items.len == recv.capacity)` + `return recv.items` —
        // when all capacity is used the caller can `allocator.free(slice)` and it
        // frees the exact allocation (items.len == capacity means no extra capacity
        // was allocated beyond what's returned).  Look for `recv . capacity` within
        // 30 tokens before the return statement.
        {
            const back: Ast.TokenIndex = 30;
            const scan_start: Ast.TokenIndex = if (t >= back) t - back else 0;
            var k = scan_start;
            var found_capacity = false;
            while (k + 2 < t) : (k += 1) {
                if (tags[k] != .identifier) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(k), recv)) continue;
                if (tags[k + 1] != .period) continue;
                if (tags[k + 2] != .identifier) continue;
                if (std.mem.eql(u8, tree.tokenSlice(k + 2), "capacity")) {
                    found_capacity = true;
                    break;
                }
            }
            if (found_capacity) continue;
        }

        try report(gpa, problems, tree, t);
    }
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    return_tok: Ast.TokenIndex,
) !void {
    const recv = tree.tokenSlice(return_tok + 1);
    const msg = try std.fmt.allocPrint(
        gpa,
        "`return {s}.items` — the caller receives a slice but cannot free the ArrayList's backing allocation; use `return {s}.toOwnedSlice()` to transfer ownership of exactly the used bytes, or document that this is an intentional borrow",
        .{ recv, recv },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, return_tok),
        .end = Pos.fromTokenEnd(tree, return_tok + 4),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "return-arraylist-items: fires" {
    try testing.expectFires(check, R,
        \\fn convert(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        \\    var list = try std.ArrayList(u8).initCapacity(allocator, input.len);
        \\    try list.appendSlice(input);
        \\    return list.items;
        \\}
        \\
    );
}

test "return-arraylist-items: toOwnedSlice does not fire" {
    try testing.expectNoFire(check,
        \\fn convert(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        \\    var list = try std.ArrayList(u8).initCapacity(allocator, input.len);
        \\    try list.appendSlice(input);
        \\    return list.toOwnedSlice();
        \\}
        \\
    );
}

test "return-arraylist-items: self.items does not fire" {
    try testing.expectNoFire(check,
        \\const Buf = struct { items: []u8 };
        \\fn getItems(self: *Buf) []u8 {
        \\    return self.items;
        \\}
        \\
    );
}

test "return-arraylist-items: this.items does not fire" {
    try testing.expectNoFire(check,
        \\const Buf = struct { items: []u8 };
        \\fn getItems(this: *Buf) []u8 {
        \\    return this.items;
        \\}
        \\
    );
}

test "return-arraylist-items: full-capacity assert suppresses" {
    try testing.expectNoFire(check,
        \\fn build(allocator: Allocator) ![]u8 {
        \\    var array = try std.ArrayList(u8).initCapacity(allocator, 64);
        \\    try fill(&array);
        \\    assert(array.items.len == array.capacity);
        \\    return array.items;
        \\}
        \\
    );
}

test "return-arraylist-items: no capacity check still fires" {
    try testing.expectFires(check, R,
        \\fn build(allocator: Allocator) ![]u8 {
        \\    var list = try std.ArrayList(u8).initCapacity(allocator, 64);
        \\    try list.appendSlice(data);
        \\    return list.items;
        \\}
        \\
    );
}
