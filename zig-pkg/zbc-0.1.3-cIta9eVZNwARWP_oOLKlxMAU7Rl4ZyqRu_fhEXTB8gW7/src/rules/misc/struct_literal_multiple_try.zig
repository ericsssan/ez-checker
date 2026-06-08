//! Detects two or more `.field = try <expr>` inside the same struct literal (or
//! initializer).  If the first `try` succeeds but the second `try` propagates an
//! error, the allocation made by the first `try` leaks — `errdefer` cannot be
//! placed inside a struct literal expression.
//!
//! Real-world instance:
//!   - ziglang/zig#23285 (std.zig.Ast.parse):
//!       return Ast{
//!           .extra_data = try parser.extra_data.toOwnedSlice(gpa),  // succeeds
//!           .errors     = try parser.errors.toOwnedSlice(gpa),       // fails → leak
//!       };
//!     Fix: bind each to a local with `errdefer`, then build the struct literal
//!     from the locals.
//!
//! Detection (Tier 1, token walk with paren-skip):
//!   Pattern: `. identifier = keyword_try ... , . identifier = keyword_try`
//!   — find the first `.field = try` 4-token prefix, skip to the next `,` at
//!   depth 0, then check whether the following tokens are `. identifier = try`.
//!   Fire at the second `.` token (the start of the second field assignment).
//!
//!   The leak only matters if the FIRST `try` actually allocates an owned
//!   resource (the second `try` failing is what leaks the first's allocation).
//!   So the first try-expression must contain an allocation signal —
//!   `alloc`, `dupe`, `clone`, `create`, or `toOwnedSlice`.  Decoder/parser
//!   tries (`read_int`, `read_enum`, `parseUnsigned`) return value types and
//!   leak nothing, so they are suppressed.

const std = @import("std");
const Ast = std.zig.Ast;

const problem_mod = @import("../../problem.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");
const testing = @import("../../testing.zig");

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const R = "struct-literal-multiple-try";

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .struct_literal_multiple_try)) return;

    const tags = tree.tokens.items(.tag);
    if (tree.tokens.len < 8) return;
    const last_tok: Ast.TokenIndex = @intCast(tree.tokens.len -| 1);

    // Map identifier-reference nodes by main token, so the first-try
    // expression's operands can be resolved to their types (e.g. is an operand
    // a `std.mem.Allocator`?).  Empty/unused when the type engine is absent.
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
    while (t + 7 <= last_tok) : (t += 1) {
        // First field: . identifier = try
        if (tags[t] != .period) continue;
        if (tags[t + 1] != .identifier) continue;
        if (tags[t + 2] != .equal) continue;
        if (tags[t + 3] != .keyword_try) continue;

        // Skip to ',' at depth 0 (end of this field's initializer)
        var i = t + 4;
        var depth: u32 = 0;
        while (i <= last_tok) : (i += 1) {
            switch (tags[i]) {
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => {
                    if (depth == 0) break; // closing delimiter of the struct literal
                    depth -= 1;
                },
                .comma => if (depth == 0) break,
                else => {},
            }
        }
        if (i > last_tok) continue;
        if (tags[i] != .comma) continue; // hit a closing delimiter — skip

        // The first try-expression (t+4 .. comma) must allocate an owned
        // resource — otherwise nothing leaks when a later try fails.  The
        // SEMANTIC signal (`firstTryUsesAllocator`) recognizes that the call
        // takes/uses a `std.mem.Allocator` value (the type-based ownership
        // signal — `gpa.alloc`, `list.toOwnedSlice(gpa)`, `el.deepClone(alloc)`
        // all reference an Allocator; a borrowed `getView()` does not).  The
        // syntactic name proxy still catches internal-alloc calls with no
        // visible allocator operand (`x.clone()`).
        if (!firstTryUsesAllocator(cache, &ident_nodes, tags, t + 4, i) and
            !tryExprAllocates(tree, tags, t + 4, i)) continue;

        // If the surrounding function uses an arena-backed allocator (i.e.
        // there is a `const X = ARENA.allocator()` within 200 tokens before
        // this struct literal, or the first-try expression passes an
        // "arena"-named argument directly, or the enclosing function has
        // `errdefer ARENA.deinit()`), every allocation is freed when the
        // arena resets — no per-field leak is possible even if a later
        // `try` fails.
        if (nearbyArenaAllocator(tree, tags, t)) continue;
        if (tryExprPassesArena(tree, tags, t + 4, i)) continue;
        if (enclosingFnHasArenaErrdefer(tree, tags, t)) continue;

        // Check the next field starts with . identifier = try
        const next = i + 1;
        if (next + 3 > last_tok) continue;
        if (tags[next] != .period) continue;
        if (tags[next + 1] != .identifier) continue;
        if (tags[next + 2] != .equal) continue;
        if (tags[next + 3] != .keyword_try) continue;

        const field1 = tree.tokenSlice(t + 1);
        const field2 = tree.tokenSlice(next + 1);

        try report(gpa, problems, tree, next, field1, field2);
    }
}

/// SEMANTIC allocation signal: returns true iff some identifier operand in the
/// first-try expression `[start, end)` resolves to type `std.mem.Allocator`
/// AND is in receiver position (followed by `.`).  Requiring receiver position
/// avoids signalling on pool/builder patterns like `pool.put(allocator, bytes)`
/// where the allocator is passed as an argument — the allocation goes into
/// the pool's internal buffer, not directly to the caller, so there is no
/// individual per-field leak from the struct-literal failure.
/// No-op (false) when the type engine is absent.
fn firstTryUsesAllocator(
    cache: *file_cache_mod.FileCache,
    ident_nodes: *const std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.Index),
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
) bool {
    var t = start;
    while (t < end) : (t += 1) {
        if (tags[t] != .identifier) continue;
        const node = ident_nodes.get(t) orelse continue;
        const tyname = cache.typeNameOfNode(node) orelse continue;
        if (!std.mem.eql(u8, tyname, "Allocator")) continue;
        // Allocator must be in receiver position (followed by '.') — e.g.
        // `gpa.alloc(T, n)`.  If followed by ',' or ')' the allocator is
        // an argument to a pool/builder and does not individually leak.
        if (t + 1 < end and tags[t + 1] == .period) return true;
    }
    return false;
}

/// Returns true iff the token range [start, end) contains an identifier or
/// builtin whose slice (case-insensitively) contains an allocation signal:
/// `alloc`, `dupe`, `clone`, `create`, or `ownedslice` (covers
/// `toOwnedSlice`).  These are the calls that hand back an owned resource a
/// failing later `try` would leak.  Decoders/parsers (`read_*`, `parse*`)
/// return value types and match no signal, so they are suppressed.
///
/// Precision rules to avoid over-signalling:
///   - "alloc" in any form (the common allocator variable name, allocPrint,
///     allocate, …) only signals when in method-call position (preceded by
///     `.`) or direct-call position (followed by `(`).  Bare `allocator`
///     passed as an argument to a pool or builder — e.g.
///     `pool.put(allocator, bytes)` — does NOT signal because the
///     allocation goes into the pool's internal buffer, not to the caller.
///   - "create" only signals for method calls (preceded by `.`).
///   - "dupe", "clone", "ownedslice" signal in any position.
fn tryExprAllocates(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
) bool {
    var t = start;
    while (t < end) : (t += 1) {
        if (tags[t] != .identifier and tags[t] != .builtin) continue;
        const s = tree.tokenSlice(t);
        if (containsIgnoreCase(s, "dupe") or
            containsIgnoreCase(s, "clone") or
            containsIgnoreCase(s, "ownedslice")) return true;
        // "alloc" in any form: require method-call (preceded by '.') or
        // direct-call (followed by '(') position to exclude allocator
        // variable names passed as arguments.
        if (containsIgnoreCase(s, "alloc")) {
            const before_is_dot = t > start and tags[t - 1] == .period;
            const after_is_paren = t + 1 < end and tags[t + 1] == .l_paren;
            if (before_is_dot or after_is_paren) return true;
        }
        // "create": only signal for method calls (preceded by '.')
        if (containsIgnoreCase(s, "create") and t > start and tags[t - 1] == .period) return true;
    }
    return false;
}

/// Returns true if within 100 tokens before `anchor` there is a declaration
/// of the form `IDENT_ARENA . allocator ( )`, indicating the function is
/// using an arena-backed allocator.  In that case every allocation in this
/// scope is freed when the arena resets, so no per-field leak is possible.
fn nearbyArenaAllocator(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    anchor: Ast.TokenIndex,
) bool {
    const back: Ast.TokenIndex = 200;
    const start: Ast.TokenIndex = if (anchor >= back) anchor - back else 0;
    var k = start;
    while (k + 4 < anchor) : (k += 1) {
        if (tags[k] != .identifier) continue;
        if (std.ascii.findIgnoreCase(tree.tokenSlice(k), "arena") == null) continue;
        if (tags[k + 1] != .period) continue;
        if (tags[k + 2] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k + 2), "allocator")) continue;
        if (tags[k + 3] != .l_paren) continue;
        if (tags[k + 4] != .r_paren) continue;
        return true;
    }
    return false;
}

/// Returns true if within the backward scan from `anchor` (up to 1000 tokens)
/// there is an `errdefer IDENT_ARENA . deinit` pattern.  Long function bodies
/// can place `errdefer arena.deinit()` hundreds of tokens before the struct
/// literal, beyond the 200-token window of `nearbyArenaAllocator`.  When such
/// an errdefer exists, all arena-backed allocations in the function are cleaned
/// up on error, so no per-field leak is possible.
fn enclosingFnHasArenaErrdefer(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    anchor: Ast.TokenIndex,
) bool {
    const back: Ast.TokenIndex = 1000;
    const start: Ast.TokenIndex = if (anchor >= back) anchor - back else 0;
    var k = start;
    while (k + 4 < anchor) : (k += 1) {
        if (tags[k] != .keyword_errdefer) continue;
        if (tags[k + 1] != .identifier) continue;
        if (std.ascii.findIgnoreCase(tree.tokenSlice(k + 1), "arena") == null) continue;
        if (tags[k + 2] != .period) continue;
        if (tags[k + 3] != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(k + 3), "deinit")) continue;
        return true;
    }
    return false;
}

/// Returns true if the first-try expression `[start, end)` passes an
/// "arena"-named identifier as a CALL ARGUMENT (in argument position,
/// i.e. preceded by `(` or `,`).  This covers the common pattern of
/// passing an arena allocator parameter directly — e.g.
/// `pool.toOwnedSlice(arena)` — where `arena: std.mem.Allocator` is a
/// function parameter rather than derived from `arena.allocator()`.
/// In that case, allocations go into the arena and are freed as a unit
/// when the caller destroys the arena, so no individual field leaks.
fn tryExprPassesArena(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
) bool {
    if (start >= end) return false;
    var t = start;
    while (t < end) : (t += 1) {
        if (tags[t] != .identifier) continue;
        if (std.ascii.findIgnoreCase(tree.tokenSlice(t), "arena") == null) continue;
        // Require argument position: preceded by '(' or ','.
        if (t == start) continue; // first token, no predecessor
        const prev = tags[t - 1]; // zbc-disable-line: index-minus-one-without-zero-guard — t==start is skipped above; t>start>=1 in fall-through
        if (prev == .l_paren or prev == .comma) return true;
    }
    return false;
}

/// Case-insensitive substring test (`needle` must be lowercase).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != needle[j]) continue :outer;
        }
        return true;
    }
    return false;
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    second_tok: Ast.TokenIndex,
    field1: []const u8,
    field2: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`.{s} = try ...` followed by `.{s} = try ...` in the same initializer — if the second `try` fails, the allocation from the first leaks because `errdefer` cannot appear inside a struct literal; bind each to a local with `errdefer` first",
        .{ field1, field2 },
    );
    errdefer gpa.free(msg);
    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, second_tok),
        .end = Pos.fromTokenEnd(tree, second_tok + 3),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "struct-literal-multiple-try: fires on two try fields" {
    try testing.expectFires(check, R,
        \\fn parse(gpa: Allocator, parser: *Parser) !Ast {
        \\    return Ast{
        \\        .extra_data = try parser.extra_data.toOwnedSlice(gpa),
        \\        .errors     = try parser.errors.toOwnedSlice(gpa),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: single try field does not fire" {
    try testing.expectNoFire(check,
        \\fn parse(gpa: Allocator, parser: *Parser) !Ast {
        \\    return Ast{
        \\        .extra_data = try parser.extra_data.toOwnedSlice(gpa),
        \\        .errors     = &.{},
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: non-try second field does not fire" {
    try testing.expectNoFire(check,
        \\fn build() Foo {
        \\    return Foo{
        \\        .a = compute(),
        \\        .b = 42,
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: fires in return with named init" {
    try testing.expectFires(check, R,
        \\fn makeNode(gpa: Allocator) !Node {
        \\    return Node{
        \\        .name  = try gpa.dupe(u8, "hello"),
        \\        .value = try gpa.dupe(u8, "world"),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: decoder tries (no allocation) do not fire" {
    try testing.expectNoFire(check,
        \\fn readHeader(self: *Decoder) !FrameHeader {
        \\    return .{
        \\        .type = try self.read_enum(FrameType),
        \\        .channel = try self.read_enum(Channel),
        \\        .size = try self.read_int(u32),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: parseUnsigned tries do not fire" {
    try testing.expectNoFire(check,
        \\fn parseVersion(arg_major: []const u8, arg_minor: []const u8) !Version {
        \\    return .{
        \\        .major = try std.fmt.parseUnsigned(u8, arg_major, 10),
        \\        .minor = try std.fmt.parseUnsigned(u8, arg_minor, 10),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: alloc.alloc tries fire" {
    try testing.expectFires(check, R,
        \\fn makeLexer(alloc: Allocator, n_words: usize) !Lexer {
        \\    return .{
        \\        .ident      = try alloc.alloc(u64, n_words),
        \\        .newline    = try alloc.alloc(u64, n_words),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: deepClone tries fire" {
    try testing.expectFires(check, R,
        \\fn cloneIf(allocator: Allocator, el: *If) !If {
        \\    return .{
        \\        .test_ = try el.test_.deepClone(allocator),
        \\        .yes = try el.yes.deepClone(allocator),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: try in nested call args does not fire" {
    try testing.expectNoFire(check,
        \\fn callFn(a: u8, b: u8) void {
        \\    process(a, b);
        \\}
        \\
    );
}

test "struct-literal-multiple-try: factory fn (create prefix) does not fire" {
    try testing.expectNoFire(check,
        \\fn buildStep(b: *Build) !GhosttyI18n {
        \\    return .{
        \\        .update_step = try createUpdateStep(b),
        \\        .steps = try steps.toOwnedSlice(b.allocator),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: arena allocator does not fire" {
    try testing.expectNoFire(check,
        \\fn deriveFontConfig(arena: ArenaAllocator, config: *const Config) !FontConfig {
        \\    const alloc = arena.allocator();
        \\    return .{
        \\        .@"font-family" = try config.@"font-family".clone(alloc),
        \\        .@"font-style"  = try config.@"font-style".clone(alloc),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: method .create fires" {
    try testing.expectFires(check, R,
        \\fn makeNode(gpa: Allocator) !Node {
        \\    return .{
        \\        .left  = try gpa.create(LeftNode),
        \\        .right = try gpa.create(RightNode),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: arena parameter passed to toOwnedSlice does not fire" {
    // When the arena allocator is passed directly as a parameter — e.g.
    // `fn f(arena: std.mem.Allocator)` — and the first-try expression is
    // `try x.toOwnedSlice(arena)`, the allocation is arena-backed and freed
    // as a unit; no individual per-field leak is possible.
    try testing.expectNoFire(check,
        \\fn writeRecord(arena: Allocator, out: *ArrayList(u8), map: *ArrayList(u32)) !Result {
        \\    return Result{
        \\        .bytes = try out.toOwnedSlice(arena),
        \\        .source_offsets = try map.toOwnedSlice(arena),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: pool.put(allocator, bytes) does not fire" {
    // pool.put(allocator, bytes) passes the allocator as an ARGUMENT to a
    // pool/builder — all puts go into the pool's internal buffer and are freed
    // as a unit when the pool is destroyed.  The `allocator` variable name
    // contains "alloc" but is NOT in receiver position, so neither the
    // type-based nor name-based allocation signals should fire.
    try testing.expectNoFire(check,
        \\fn writeRecord(allocator: Allocator, pool: *PoolBuilder, ln: Line) !Record {
        \\    return Record{
        \\        .source = try pool.put(allocator, ln.source),
        \\        .tokens = try pool.put(allocator, ln.tokens),
        \\    };
        \\}
        \\
    );
}

test "struct-literal-multiple-try: errdefer arena.deinit() in enclosing fn suppresses" {
    // Long function bodies place `errdefer arena.deinit()` hundreds of tokens
    // before the struct literal — beyond the nearbyArenaAllocator window.
    // The enclosingFnHasArenaErrdefer check covers this case.
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\const ArenaAllocator = std.heap.ArenaAllocator;
        \\const ArrayList = std.ArrayListUnmanaged;
        \\fn buildModel(gpa: std.mem.Allocator, count: usize) !Model {
        \\    var arena = ArenaAllocator.init(gpa);
        \\    errdefer arena.deinit();
        \\    const a = arena.allocator();
        \\    var names: ArrayList([]const u8) = .empty;
        \\    var fns: ArrayList([]const u8) = .empty;
        \\    var i: usize = 0;
        \\    while (i < count) : (i += 1) {
        \\        try names.append(a, "x");
        \\        try fns.append(a, "y");
        \\    }
        \\    return .{
        \\        .names = try names.toOwnedSlice(a),
        \\        .fns = try fns.toOwnedSlice(a),
        \\    };
        \\}
        \\const Model = struct { names: [][]const u8, fns: [][]const u8 };
        \\
    );
}

test "struct-literal-multiple-try: no errdefer arena still fires" {
    // Control: without errdefer arena.deinit(), the rule must still fire
    // so the suppressor is not inadvertently always-true.
    try testing.expectFires(check, R,
        \\const std = @import("std");
        \\fn buildPair(gpa: std.mem.Allocator) !Pair {
        \\    return Pair{
        \\        .a = try gpa.alloc(u8, 4),
        \\        .b = try gpa.alloc(u8, 4),
        \\    };
        \\}
        \\const Pair = struct { a: []u8, b: []u8 };
        \\
    );
}
