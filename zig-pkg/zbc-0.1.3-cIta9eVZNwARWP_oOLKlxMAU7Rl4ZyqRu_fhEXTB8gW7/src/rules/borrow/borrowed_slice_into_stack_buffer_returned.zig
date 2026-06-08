//! Borrowed-slice-into-stack-buffer-returned detector — a stack-
//! local `var <buf>: [N]<T> = undefined;` is passed to a known
//! aliasing parser (`SemanticVersion.parse`, etc.), and the
//! returned value (which holds slices INTO `<buf>`) flows out of
//! the fn via `return` — leaving the caller with a struct whose
//! slice fields point at the now-dead `<buf>`.
//!
//! Real-world: ziglang/zig#25713 — `std.zig.system.resolveTargetQuery`
//! parsed a kernel version into `SemanticVersion`, returned the
//! result whose `.pre` / `.build` fields aliased a stack buffer
//! freed at function return.

const std = @import("std");
const Ast = std.zig.Ast;

const tokens = @import("../../ast/tokens.zig");
const local_bindings = @import("../../model/local_bindings.zig");
const fn_summary = @import("../../model/fn_summary.zig");
const query = @import("../../ast/token_query.zig");
const problem_mod = @import("../../problem.zig");
const testing = @import("../../testing.zig");
const config_mod = @import("../../config.zig");
const file_cache_mod = @import("../../cache/file_cache.zig");

const Problem = problem_mod.Problem;
const Pos = problem_mod.Pos;
const Atom = query.Atom;
const R = "borrowed-slice-into-stack-buffer-returned";

// `<AliasingType>.parse(` anywhere in a binding's RHS.
const parse_call = &[_]Atom{
    .{ .pred = isAliasingParserType },
    .{ .tok = .period },
    .{ .text = "parse" },
    .{ .tok = .l_paren },
};

pub fn check(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    config: *const config_mod.Config,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    if (!config_mod.isEnabled(config, .borrowed_slice_into_stack_buffer_returned)) return;
    try tokens.forEachFnCached(gpa, tree, cache, problems, checkFn);
}

fn checkFn(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    cache: *file_cache_mod.FileCache,
    proto: Ast.full.FnProto,
    body: Ast.Node.Index,
    problems: *std.ArrayListUnmanaged(Problem),
) !void {
    const tags = tree.tokens.items(.tag);
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);

    // Cheap pre-scan: no return → nothing to escape, no fire possible.
    if (!tokens.hasTokenInRange(tags, first, last, .keyword_return)) return;

    const bindings = try cache.localBindings(proto, body);

    // Pass 1: stack array locals.
    // Shape: `var <name>: [<...>]<T> = undefined;`.  local.zig doesn't
    // store the type annotation, but the syntax around name_token
    // gives it away: name_token+1 is `:` and name_token+2 is `[`.
    // RHS is the identifier "undefined" (classified as .literal by
    // local.zig).
    var stack_bufs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack_bufs.deinit(gpa);
    for (bindings.items) |b| {
        if (b.is_const) continue;
        if (b.origin != .literal) continue;
        if (b.name_token + 2 > last) continue;
        if (tags[b.name_token + 1] != .colon) continue;
        if (tags[b.name_token + 2] != .l_bracket) continue;
        // RHS sanity-check: "undefined".
        if (!std.mem.eql(u8, tree.tokenSlice(b.rhs_first), "undefined")) continue;
        try stack_bufs.append(gpa, b.name);
    }
    if (stack_bufs.items.len == 0) return;

    // Pass 2: tainted bindings — a binding whose RHS passes a stack buffer to
    // a call that returns slices INTO that buffer.  Two detectors:
    //   (1) hardcoded aliasing parsers `<AliasingType>.parse(&buf)` — covers the
    //       struct-with-aliasing-fields shape the summary engine can't infer
    //       (`return .{ .pre = buf[a..b] }` classifies as `.unknown`); and
    //   (2) SEMANTIC: any callee whose FnSummary says the result borrows from an
    //       argument (`returns == .borrowed_from(N)`) and arg N mentions a stack
    //       buffer.  Generalises (1) from 3 hardcoded types to every borrowing
    //       callee the summary infers (e.g. `fn subslice(buf) []u8 { return buf[1..]; }`).
    var tainted: std.ArrayListUnmanaged([]const u8) = .empty;
    defer tainted.deinit(gpa);
    for (bindings.items) |b| {
        if (b.origin == .param) continue;
        if (try bindingBorrowsStackBuf(gpa, cache, tree, tags, b.rhs_first, b.rhs_last, stack_bufs.items)) {
            try tainted.append(gpa, b.name);
        }
    }
    if (tainted.items.len == 0) return;

    // Pass 3: scan returns for any tainted ident.
    var t: Ast.TokenIndex = first;
    while (t <= last) : (t += 1) {
        if (tags[t] == .keyword_fn) {
            t = tokens.skipNestedFn(tags, t, last);
            continue;
        }
        if (tags[t] != .keyword_return) continue;
        const sc = tokens.findStmtSemicolon(tags, t + 1, last) orelse continue;
        if (sc <= t + 1) continue;
        // Only fire when a tainted value escapes UNCOPIED — i.e. it appears in
        // the return expression outside any call's argument list.  A tainted
        // value passed through a call (`return join(alloc, &.{v})`) is copied
        // into a fresh allocation and no longer aliases the dead buffer.
        if (rangeMentionsNameUncopied(tree, t + 1, sc - 1, tainted.items)) |n| {
            try report(gpa, problems, tree, t, n);
        }
        t = sc;
    }
}

/// True iff the binding RHS `[rhs_first, rhs_last]` passes a stack buffer to a
/// call whose result borrows it — via the hardcoded aliasing-parser shape OR a
/// summary-inferred `borrowed_from` callee.
fn bindingBorrowsStackBuf(
    gpa: std.mem.Allocator,
    cache: *file_cache_mod.FileCache,
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    rhs_first: Ast.TokenIndex,
    rhs_last: Ast.TokenIndex,
    stack_bufs: []const []const u8,
) !bool {
    _ = gpa;
    // (1) Hardcoded `<AliasingType>.parse(<expr mentioning buf>)`.
    if (findFirstMatchInRange(tree, parse_call, rhs_first, rhs_last)) |parse_m| {
        const lp = parse_m.end;
        if (tokens.matchParen(tags, lp, rhs_last)) |rp| {
            if (rangeMentionsAny(tree, lp + 1, rp - 1, stack_bufs)) return true;
        }
    }
    // (2) Summary-inferred borrowed_from callee.
    return rhsCallBorrowsStackBuf(cache, tree, tags, rhs_first, rhs_last, stack_bufs);
}

/// Scan the RHS for a call to a callee whose `FnSummary.returns` is
/// `.borrowed_from(N)`, and test whether call-argument N mentions a stack
/// buffer.  Resolves only same-file FREE functions (`f(...)`) and STATIC
/// methods on a named type (`T.m(...)`, `T` uppercase) — argument indices map
/// directly to parameter indices there.  Value-receiver and cross-file calls
/// need the type engine; they don't resolve here and simply don't fire (sound).
fn rhsCallBorrowsStackBuf(
    cache: *file_cache_mod.FileCache,
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    rhs_first: Ast.TokenIndex,
    rhs_last: Ast.TokenIndex,
    stack_bufs: []const []const u8,
) !bool {
    var p = rhs_first;
    while (p <= rhs_last) : (p += 1) {
        if (tags[p] != .l_paren) continue;
        if (p == 0 or tags[p - 1] != .identifier) continue;

        const summary: ?*const fn_summary.FnSummary = sum: {
            // Static method `T.method(` — T a named type (uppercase), not a
            // longer chain (`a.T.method` → value receiver, skip).
            if (p >= 3 and tags[p - 2] == .period and tags[p - 3] == .identifier and
                (p < 4 or tags[p - 4] != .period))
            {
                const tname = tree.tokenSlice(p - 3);
                if (tname.len > 0 and std.ascii.isUpper(tname[0])) {
                    break :sum try cache.summaryByMethod(tname, tree.tokenSlice(p - 1));
                }
                break :sum null;
            }
            // Free function `f(` — preceding token is not a `.` qualifier.
            if (p < 2 or tags[p - 2] != .period) {
                break :sum try cache.summaryByName(tree.tokenSlice(p - 1));
            }
            break :sum null;
        };
        const s = summary orelse continue;
        const borrowed_idx = switch (s.returns) {
            .borrowed_from => |i| i,
            else => continue,
        };
        const rp = tokens.matchParen(tags, p, rhs_last) orelse continue;
        if (argMentionsBuf(tree, tags, p, rp, borrowed_idx, stack_bufs)) return true;
    }
    return false;
}

/// In the call-argument list spanning (`lp` .. `rp`), find the top-level
/// (comma-separated, paren/bracket/brace-balanced) argument at index `idx` and
/// test whether it mentions any stack buffer.
fn argMentionsBuf(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    lp: Ast.TokenIndex,
    rp: Ast.TokenIndex,
    idx: u32,
    stack_bufs: []const []const u8,
) bool {
    if (rp <= lp + 1) return false; // empty arg list
    var depth: i32 = 0;
    var cur_arg: u32 = 0;
    var arg_start: Ast.TokenIndex = lp + 1;
    var t: Ast.TokenIndex = lp + 1;
    while (t < rp) : (t += 1) {
        switch (tags[t]) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -= 1,
            .comma => if (depth == 0) {
                if (cur_arg == idx) return rangeMentionsAny(tree, arg_start, t - 1, stack_bufs);
                cur_arg += 1;
                arg_start = t + 1;
            },
            else => {},
        }
    }
    // Last argument (no trailing top-level comma).
    if (cur_arg == idx) return rangeMentionsAny(tree, arg_start, rp - 1, stack_bufs);
    return false;
}

/// Find the first match of `atoms` in `[start, end]` via a forward
/// scan.  No scope/defer/nested-fn skipping — used to scan a single
/// binding's RHS where those concerns don't apply.
fn findFirstMatchInRange(
    tree: *const Ast,
    atoms: []const Atom,
    start: Ast.TokenIndex,
    end: Ast.TokenIndex,
) ?query.Match {
    if (start > end) return null;
    var t: Ast.TokenIndex = start;
    while (t <= end) : (t += 1) {
        if (query.matchAt(tree, atoms, t, end, null)) |m| return m;
    }
    return null;
}

/// True iff `[start, end]` mentions any name in `names` as an
/// identifier.
fn rangeMentionsAny(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, names: []const []const u8) bool {
    const tags = tree.tokens.items(.tag);
    if (start > end) return false;
    var t: Ast.TokenIndex = start;
    while (t <= end) : (t += 1) {
        if (tags[t] != .identifier) continue;
        const id = tree.tokenSlice(t);
        for (names) |n| if (std.mem.eql(u8, n, id)) return true;
    }
    return false;
}

/// Like rangeMentionsAny but returns the matched name on hit.
fn rangeMentionsName(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, names: []const []const u8) ?[]const u8 {
    const tags = tree.tokens.items(.tag);
    if (start > end) return null;
    var t: Ast.TokenIndex = start;
    while (t <= end) : (t += 1) {
        if (tags[t] != .identifier) continue;
        const id = tree.tokenSlice(t);
        for (names) |n| if (std.mem.eql(u8, n, id)) return n;
    }
    return null;
}

/// Like rangeMentionsName, but only matches an identifier that is NOT inside a
/// call's argument list — i.e. it reaches the `return` UNCOPIED.  A borrowed
/// value passed through a call (`return std.fs.path.join(alloc, &.{v})`) is
/// copied into a fresh allocation and no longer aliases the stack buffer, so it
/// must not fire.  A `(` is a CALL paren when preceded by an identifier / `)` /
/// `]` / builtin (`@as(`); grouping parens (`return (v)`) do not copy and are
/// not counted.  Tracks per-paren call-ness on a small stack; bails safely
/// (no fire) past an absurd nesting depth.
fn rangeMentionsNameUncopied(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, names: []const []const u8) ?[]const u8 {
    const tags = tree.tokens.items(.tag);
    if (start > end) return null;
    var paren_is_call: [64]bool = undefined;
    var sp: usize = 0;
    var call_depth: u32 = 0;
    var t: Ast.TokenIndex = start;
    while (t <= end) : (t += 1) {
        switch (tags[t]) {
            .l_paren => {
                const is_call = t > 0 and switch (tags[t - 1]) {
                    .identifier, .r_paren, .r_bracket, .builtin => true,
                    else => false,
                };
                if (sp >= paren_is_call.len) return null; // absurd depth → no fire
                paren_is_call[sp] = is_call;
                sp += 1;
                if (is_call) call_depth += 1;
            },
            .r_paren => if (sp > 0) {
                sp -= 1;
                if (paren_is_call[sp]) call_depth -|= 1;
            },
            .identifier => if (call_depth == 0) {
                const id = tree.tokenSlice(t);
                for (names) |n| if (std.mem.eql(u8, n, id)) return n;
            },
            else => {},
        }
    }
    return null;
}

fn isAliasingParserType(name: []const u8) bool {
    return std.mem.eql(u8, name, "SemanticVersion") or
        std.mem.eql(u8, name, "Uri") or
        std.mem.eql(u8, name, "Url");
}

fn report(
    gpa: std.mem.Allocator,
    problems: *std.ArrayListUnmanaged(Problem),
    tree: *const Ast,
    return_tok: Ast.TokenIndex,
    tainted_name: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        gpa,
        "`return <expr mentioning {s}>` — `{s}` holds slices that borrow a stack-local buffer: the callee returns a value aliasing its buffer argument (e.g. `SemanticVersion.parse` populating `.pre`/`.build`, or any function returning `arg[a..b]`), but the buffer dies at fn return, leaving the caller with dangling slices.  Clone the borrowed data (or strip the aliasing fields) before returning",
        .{ tainted_name, tainted_name },
    );
    errdefer gpa.free(msg);

    try problems.append(gpa, .{
        .rule_id = R,
        .severity = .@"error",
        .start = Pos.fromTokenStart(tree, return_tok),
        .end = Pos.fromTokenEnd(tree, return_tok),
        .message = msg,
    });
}

// ── Tests ──────────────────────────────────────────────────

test "SemanticVersion.parse pattern fires" {
    try testing.expectFires(check, R,
        \\const std = @import("std");
        \\const SemanticVersion = struct {
        \\    pre: ?[]const u8 = null,
        \\    build: ?[]const u8 = null,
        \\    pub fn parse(_: []const u8) SemanticVersion { return .{}; }
        \\};
        \\pub fn detect() SemanticVersion {
        \\    var buf: [64]u8 = undefined;
        \\    const ver = SemanticVersion.parse(&buf);
        \\    return ver;
        \\}
    );
}

test "parse on a non-stack-buf doesn't fire" {
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\const SemanticVersion = struct {
        \\    pub fn parse(_: []const u8) SemanticVersion { return .{}; }
        \\};
        \\pub fn detect(text: []const u8) SemanticVersion {
        \\    const ver = SemanticVersion.parse(text);
        \\    return ver;
        \\}
    );
}

test "parse result not returned doesn't fire" {
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\const SemanticVersion = struct {
        \\    pub fn parse(_: []const u8) SemanticVersion { return .{}; }
        \\};
        \\pub fn detect() void {
        \\    var buf: [64]u8 = undefined;
        \\    const ver = SemanticVersion.parse(&buf);
        \\    _ = ver;
        \\}
    );
}

// ── Semantic (FnSummary.borrowed_from) detector ─────────────

test "summary: free fn returning arg[a..] of a stack buf, returned, fires" {
    try testing.expectFires(check, R,
        \\fn subslice(buf: []u8) []u8 { return buf[1..]; }
        \\pub fn detect() []u8 {
        \\    var b: [16]u8 = undefined;
        \\    const s = subslice(&b);
        \\    return s;
        \\}
    );
}

test "summary: static method returning arg[a..] of a stack buf, returned, fires" {
    try testing.expectFires(check, R,
        \\const Slicer = struct {
        \\    fn subslice(buf: []u8) []u8 { return buf[1..]; }
        \\};
        \\pub fn detect() []u8 {
        \\    var b: [16]u8 = undefined;
        \\    const s = Slicer.subslice(&b);
        \\    return s;
        \\}
    );
}

test "summary: allocating callee (returns owned/heap) does not fire" {
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\fn dupe(gpa: std.mem.Allocator, buf: []u8) []u8 {
        \\    const r = gpa.alloc(u8, buf.len) catch unreachable;
        \\    return r;
        \\}
        \\pub fn detect(gpa: std.mem.Allocator) []u8 {
        \\    var b: [16]u8 = undefined;
        \\    const s = dupe(gpa, &b);
        \\    return s;
        \\}
    );
}

test "summary: borrowed value COPIED through an allocating call before return does not fire" {
    // The resourcesdir.zig shape: `v` borrows the stack buffer, but is passed
    // through `join(alloc, ...)` which copies it into a fresh allocation, so the
    // returned value does not alias the dead buffer.
    try testing.expectNoFire(check,
        \\const std = @import("std");
        \\fn subslice(buf: []u8) []u8 { return buf[1..]; }
        \\fn join(a: std.mem.Allocator, parts: []const []const u8) []u8 {
        \\    return a.alloc(u8, parts.len) catch unreachable;
        \\}
        \\pub fn detect(alloc: std.mem.Allocator) []u8 {
        \\    var b: [16]u8 = undefined;
        \\    const v = subslice(&b);
        \\    return join(alloc, &.{ v, "x" });
        \\}
    );
}

test "summary: borrowed_from a NON-buffer arg does not fire" {
    try testing.expectNoFire(check,
        \\fn subslice(buf: []u8) []u8 { return buf[1..]; }
        \\pub fn detect(input: []u8) []u8 {
        \\    var b: [16]u8 = undefined;
        \\    _ = &b;
        \\    const s = subslice(input);
        \\    return s;
        \\}
    );
}
