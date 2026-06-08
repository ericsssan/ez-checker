//! Standalone intra-procedural value-range oracle (Track B).
//!
//! Answers two sound questions for a single function body, on every path that
//! reaches a given use token:
//!   - `provesNonzero(local)`   — is unsigned scalar `local` provably != 0?
//!   - `provesNonempty(path)`   — is container `path` provably non-empty
//!                                 (i.e. `path.len >= 1`)?
//!
//! Both are the facts `index-minus-one-without-zero-guard` needs: for an
//! unsigned `i`, `i != 0` ⟺ `i - 1` cannot underflow; for a container `c`,
//! `c.len != 0` ⟺ `c.len - 1` cannot underflow.
//!
//! Design — a structured forward abstract interpretation over the AST.  ONE
//! control-flow walk threads a `State` carrying two independent fact sets
//! (nonzero scalars, non-empty containers), so if/else merge, divergence, and
//! loop handling are written once.  It is deliberately NOT built on
//! `src/flow/`'s CFG: that CFG discards branch truthiness (cfg_builder: "We
//! don't model the condition's truthiness") — exactly the information
//! value-range needs — and its state/worklist are hardwired to the lifetime
//! lattice.  Standalone keeps the working escape/UAF/double-free analysis
//! untouched; promotable into a shared CFG domain later.
//!
//! Soundness: each set UNDER-approximates "definitely true".  Every transfer
//! preserves a fact only when provably valid, else drops it; any uncertainty
//! (unrecognized assignment, container mutation, loop body, unmodeled
//! construct) → fact absent → query returns false → the rule fires.  Oracle
//! false-negatives only cost suppression recall, never a missed bug.
//!
//! Scalar facts:    added by `x = <positive int literal>`; refined inside arms
//!                  by `x > 0` / `x != 0` / `x >= 1` / `0 < x` (+ `== 0` else
//!                  duals); dropped on any other assignment to x.
//! Container facts: refined inside arms by `c.len > 0` / `!= 0` / `>= 1` /
//!                  `0 < c.len` (+ `== 0` else duals); dropped when `c` is
//!                  mutated (append/insert/resize/clear/pop/remove/… or
//!                  reassigned).  Never added by straight-line code (growth is
//!                  not tracked) — only guards establish non-emptiness.

const std = @import("std");
const Ast = std.zig.Ast;
const file_cache_mod = @import("../cache/file_cache.zig");

/// A set of string keys (source slices, stable for the tree's lifetime).
const KeySet = struct {
    keys: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *KeySet, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }
    fn contains(self: *const KeySet, k: []const u8) bool {
        for (self.keys.items) |e| if (std.mem.eql(u8, e, k)) return true;
        return false;
    }
    fn add(self: *KeySet, gpa: std.mem.Allocator, k: []const u8) !void {
        if (self.contains(k)) return;
        try self.keys.append(gpa, k);
    }
    fn remove(self: *KeySet, k: []const u8) void {
        var i: usize = 0;
        while (i < self.keys.items.len) {
            if (std.mem.eql(u8, self.keys.items[i], k)) {
                _ = self.keys.swapRemove(i);
            } else i += 1;
        }
    }
    fn intersectWith(self: *KeySet, other: *const KeySet) void {
        var i: usize = 0;
        while (i < self.keys.items.len) {
            if (other.contains(self.keys.items[i])) i += 1 else _ = self.keys.swapRemove(i);
        }
    }
};

/// A `const n = c.len` binding: scalar `n` snapshots container `c`'s length.
/// Lets a guard on either side establish the other's fact (nonzero(n) ⟺
/// nonempty(c)).  Dropped when `n` is rebound or `c` is mutated.
const Alias = struct { scalar: []const u8, container: []const u8 };

/// A `const DIFF = MINUEND - SUBTRAHEND` binding.
/// Propagation: DIFF nonzero AND SUBTRAHEND provably >= 0 → MINUEND nonzero.
/// Sound because MINUEND - SUBTRAHEND > 0 and SUBTRAHEND >= 0 implies MINUEND >= 1.
/// Dropped when DIFF or MINUEND is rebound.
const DiffAlias = struct {
    diff: []const u8,
    minuend: []const u8,
    sub_node: Ast.Node.Index, // AST node of the subtrahend (for provablyNonneg check)
};

/// Abstract state: two fact sets + len-alias bindings + diff-alias bindings.
const State = struct {
    scalars: KeySet = .{}, // locals known != 0
    containers: KeySet = .{}, // container paths known non-empty
    aliases: std.ArrayListUnmanaged(Alias) = .empty, // n == c.len
    diff_aliases: std.ArrayListUnmanaged(DiffAlias) = .empty, // n = A - B

    fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.scalars.deinit(gpa);
        self.containers.deinit(gpa);
        self.aliases.deinit(gpa);
        self.diff_aliases.deinit(gpa);
    }
    fn clone(self: *const State, gpa: std.mem.Allocator) !State {
        var out: State = .{};
        errdefer out.deinit(gpa);
        try out.scalars.keys.appendSlice(gpa, self.scalars.keys.items);
        try out.containers.keys.appendSlice(gpa, self.containers.keys.items);
        try out.aliases.appendSlice(gpa, self.aliases.items);
        try out.diff_aliases.appendSlice(gpa, self.diff_aliases.items);
        return out;
    }
    fn intersectWith(self: *State, other: *const State) void {
        self.scalars.intersectWith(&other.scalars);
        self.containers.intersectWith(&other.containers);
        var i: usize = 0;
        while (i < self.aliases.items.len) {
            if (other.hasAlias(self.aliases.items[i])) i += 1 else _ = self.aliases.swapRemove(i);
        }
        // Conservatively keep diff_aliases present in both states.
        var j: usize = 0;
        while (j < self.diff_aliases.items.len) {
            if (other.hasDiffAlias(self.diff_aliases.items[j])) j += 1 else _ = self.diff_aliases.swapRemove(j);
        }
    }
    fn replaceWith(self: *State, gpa: std.mem.Allocator, src: *const State) !void {
        self.scalars.keys.clearRetainingCapacity();
        self.containers.keys.clearRetainingCapacity();
        self.aliases.clearRetainingCapacity();
        self.diff_aliases.clearRetainingCapacity();
        try self.scalars.keys.appendSlice(gpa, src.scalars.keys.items);
        try self.containers.keys.appendSlice(gpa, src.containers.keys.items);
        try self.aliases.appendSlice(gpa, src.aliases.items);
        try self.diff_aliases.appendSlice(gpa, src.diff_aliases.items);
    }
    fn hasAlias(self: *const State, a: Alias) bool {
        for (self.aliases.items) |e|
            if (std.mem.eql(u8, e.scalar, a.scalar) and std.mem.eql(u8, e.container, a.container)) return true;
        return false;
    }
    fn addAlias(self: *State, gpa: std.mem.Allocator, a: Alias) !void {
        if (self.hasAlias(a)) return;
        try self.aliases.append(gpa, a);
    }
    fn dropAliasesByScalar(self: *State, scalar: []const u8) void {
        var i: usize = 0;
        while (i < self.aliases.items.len) {
            if (std.mem.eql(u8, self.aliases.items[i].scalar, scalar)) _ = self.aliases.swapRemove(i) else i += 1;
        }
    }
    fn dropAliasesByContainer(self: *State, container: []const u8) void {
        var i: usize = 0;
        while (i < self.aliases.items.len) {
            if (std.mem.eql(u8, self.aliases.items[i].container, container)) _ = self.aliases.swapRemove(i) else i += 1;
        }
    }
    fn hasDiffAlias(self: *const State, da: DiffAlias) bool {
        for (self.diff_aliases.items) |e|
            if (std.mem.eql(u8, e.diff, da.diff) and std.mem.eql(u8, e.minuend, da.minuend)) return true;
        return false;
    }
    fn addDiffAlias(self: *State, gpa: std.mem.Allocator, da: DiffAlias) !void {
        if (self.hasDiffAlias(da)) return;
        try self.diff_aliases.append(gpa, da);
    }
    /// Drop diff_aliases where the diff variable or minuend equals `name`
    /// (called when `name` is rebound — both bindings become stale).
    fn dropDiffAliasesByName(self: *State, name: []const u8) void {
        var i: usize = 0;
        while (i < self.diff_aliases.items.len) {
            const da = self.diff_aliases.items[i];
            if (std.mem.eql(u8, da.diff, name) or std.mem.eql(u8, da.minuend, name)) {
                _ = self.diff_aliases.swapRemove(i);
            } else i += 1;
        }
    }
};

const Flow = struct {
    answer: ?bool = null,
    diverged: bool = false,
};

const Query = enum { nonzero_scalar, nonempty_container };

const Oracle = struct {
    gpa: std.mem.Allocator,
    tree: *const Ast,
    query: Query,
    target: []const u8,
    use_token: Ast.TokenIndex,
    /// Optional type engine, used only to confirm a comparison operand is an
    /// UNSIGNED integer (so `key > operand` soundly implies `key >= 1`).  Null
    /// in unit tests → the type-gated `>` generalization simply doesn't apply.
    cache: ?*file_cache_mod.FileCache = null,
    budget: u32 = 50_000,

    fn tokenInNode(self: *Oracle, node: Ast.Node.Index) bool {
        return self.use_token >= self.tree.firstToken(node) and
            self.use_token <= self.tree.lastToken(node);
    }
    fn spend(self: *Oracle) bool {
        if (self.budget == 0) return false;
        self.budget -= 1;
        return true;
    }
    fn answerAt(self: *Oracle, st: *const State) bool {
        return switch (self.query) {
            .nonzero_scalar => st.scalars.contains(self.target),
            .nonempty_container => st.containers.contains(self.target),
        };
    }
};

/// Is unsigned scalar `target` provably != 0 at `use_token`?  `cache` (optional)
/// supplies the type engine for the unsigned-operand `>` generalization.
pub fn provesNonzero(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body_node: Ast.Node.Index,
    target: []const u8,
    use_token: Ast.TokenIndex,
    cache: ?*file_cache_mod.FileCache,
) bool {
    return run(gpa, tree, body_node, .nonzero_scalar, target, use_token, cache);
}

/// Is container `target` (a source-spelling like "arr" or "self.items")
/// provably non-empty (len >= 1) at `use_token`?
pub fn provesNonempty(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body_node: Ast.Node.Index,
    target: []const u8,
    use_token: Ast.TokenIndex,
    cache: ?*file_cache_mod.FileCache,
) bool {
    return run(gpa, tree, body_node, .nonempty_container, target, use_token, cache);
}

fn run(
    gpa: std.mem.Allocator,
    tree: *const Ast,
    body_node: Ast.Node.Index,
    query: Query,
    target: []const u8,
    use_token: Ast.TokenIndex,
    cache: ?*file_cache_mod.FileCache,
) bool {
    var oracle: Oracle = .{
        .gpa = gpa,
        .tree = tree,
        .query = query,
        .target = target,
        .use_token = use_token,
        .cache = cache,
    };
    var st: State = .{};
    defer st.deinit(gpa);
    const flow = analyzeNode(&oracle, body_node, &st) catch return false;
    return flow.answer orelse false;
}

fn analyzeNode(o: *Oracle, node: Ast.Node.Index, st: *State) error{OutOfMemory}!Flow {
    if (!o.spend()) return .{};
    const tree = o.tree;
    switch (tree.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            return analyzeSeq(o, blockStmts(tree, node, &buf), st);
        },
        .@"if", .if_simple => return analyzeIf(o, node, st),
        .@"while", .while_simple, .while_cont => return analyzeLoop(o, node, st, .while_),
        .@"for", .for_simple => return analyzeLoop(o, node, st, .for_),
        .simple_var_decl, .local_var_decl, .aligned_var_decl => return analyzeVarDecl(o, node, st),
        .assign => return analyzeAssign(o, node, st),
        .assign_add => return analyzeCompoundAdd(o, node, st),
        .@"return", .@"break", .@"continue", .unreachable_literal => {
            var flow: Flow = .{ .diverged = true };
            if (o.tokenInNode(node)) flow.answer = o.answerAt(st);
            return flow;
        },
        else => {
            if (o.tokenInNode(node)) return .{ .answer = o.answerAt(st) };
            // A non-containing expression statement (e.g. a call) may mutate a
            // tracked container in place — drop any it touches.  Scalars (value
            // locals) are unaffected by such statements.
            killMutatedContainers(o, node, st);
            return .{};
        },
    }
}

fn analyzeSeq(o: *Oracle, stmts: []const Ast.Node.Index, st: *State) error{OutOfMemory}!Flow {
    for (stmts) |s| {
        const flow = try analyzeNode(o, s, st);
        if (flow.answer != null) return flow;
        if (flow.diverged) return flow;
    }
    return .{};
}

fn analyzeVarDecl(o: *Oracle, node: Ast.Node.Index, st: *State) error{OutOfMemory}!Flow {
    const tree = o.tree;
    const decl = tree.fullVarDecl(node) orelse return .{};
    const name = tree.tokenSlice(decl.ast.mut_token + 1);
    const init_node = decl.ast.init_node.unwrap() orelse {
        st.scalars.remove(name);
        return .{};
    };
    if (o.tokenInNode(init_node)) {
        const flow = try analyzeNode(o, init_node, st);
        if (flow.answer != null) return flow;
    }
    if (isPositiveIntLiteral(tree, init_node)) {
        try st.scalars.add(o.gpa, name);
    } else {
        st.scalars.remove(name);
    }
    // Re-binding `name` invalidates prior facts/aliases keyed on it.
    dropContainersRootedAt(st, name);
    st.dropAliasesByScalar(name);
    st.dropDiffAliasesByName(name);
    // Record a `const/var name = <c>.len` length-snapshot alias.
    if (lenContainerPath(o, init_node)) |cpath| {
        try st.addAlias(o.gpa, .{ .scalar = name, .container = cpath });
    }
    // Record a `const/var name = MINUEND - SUBTRAHEND` diff alias.
    // Used to propagate: when `name` is proven nonzero AND the subtrahend
    // is provably >= 0 (non-negative literal, .len, or unsigned by type engine),
    // then MINUEND is also nonzero (MINUEND > SUBTRAHEND >= 0 → MINUEND >= 1).
    if (tree.nodeTag(init_node) == .sub) {
        const sub_data = tree.nodeData(init_node).node_and_node;
        if (identName(tree, sub_data[0])) |lhs_name| {
            try st.addDiffAlias(o.gpa, .{
                .diff = name,
                .minuend = lhs_name,
                .sub_node = sub_data[1],
            });
        }
    }
    return .{};
}

fn analyzeAssign(o: *Oracle, node: Ast.Node.Index, st: *State) error{OutOfMemory}!Flow {
    const tree = o.tree;
    const data = tree.nodeData(node).node_and_node;
    const lhs = data[0];
    const rhs = data[1];
    if (o.tokenInNode(rhs)) {
        const flow = try analyzeNode(o, rhs, st);
        if (flow.answer != null) return flow;
    }
    if (identName(tree, lhs)) |name| {
        if (isPositiveIntLiteral(tree, rhs)) {
            try st.scalars.add(o.gpa, name);
        } else {
            st.scalars.remove(name);
        }
        dropContainersRootedAt(st, name);
        st.dropAliasesByScalar(name);
        st.dropDiffAliasesByName(name);
        // A re-bind to `c.len` re-establishes the alias.
        if (lenContainerPath(o, rhs)) |cpath| try st.addAlias(o.gpa, .{ .scalar = name, .container = cpath });
    } else {
        // Assignment through a field/index (`c.items = ...`) — conservatively
        // drop container facts whose path the LHS could alter.
        killMutatedContainers(o, node, st);
    }
    return .{};
}

/// `x += <expr>` (non-wrapping).  For an unsigned `x`, addition never
/// decreases the value, so:
///   - `x += <positive literal>` establishes `x >= 1` (x_old >= 0 + >=1).
///     This matches safe-build semantics — `+=` panics on overflow rather than
///     wrapping; a ReleaseFast wrap would need `x == maxInt`, unreachable for a
///     loop index.  Covers `ev_i += 1; … arr[ev_i - 1]`.
///   - any other addend leaves an existing nonzero fact intact (unsigned add
///     can only grow `x`), so the fact is preserved rather than dropped.
fn analyzeCompoundAdd(o: *Oracle, node: Ast.Node.Index, st: *State) error{OutOfMemory}!Flow {
    const tree = o.tree;
    const data = tree.nodeData(node).node_and_node;
    const lhs = data[0];
    const rhs = data[1];
    if (o.tokenInNode(rhs)) {
        const flow = try analyzeNode(o, rhs, st);
        if (flow.answer != null) return flow;
    }
    if (identName(tree, lhs)) |name| {
        if (isPositiveIntLiteral(tree, rhs)) try st.scalars.add(o.gpa, name);
        // The value changed: a `n = c.len` snapshot no longer holds, and any
        // container path rooted at `name` is stale.
        dropContainersRootedAt(st, name);
        st.dropAliasesByScalar(name);
        st.dropDiffAliasesByName(name);
    } else {
        killMutatedContainers(o, node, st);
    }
    return .{};
}

fn analyzeIf(o: *Oracle, node: Ast.Node.Index, st: *State) error{OutOfMemory}!Flow {
    const tree = o.tree;
    const if_data = tree.fullIf(node) orelse return .{};
    const cond = if_data.ast.cond_expr;
    if (o.tokenInNode(cond)) return .{ .answer = o.answerAt(st) };

    var refine: Refinement = .{};
    collectRefinement(o, cond, &refine);

    const then_node = if_data.ast.then_expr;
    const else_opt = if_data.ast.else_expr.unwrap();

    var then_st = try st.clone(o.gpa);
    defer then_st.deinit(o.gpa);
    try applyRefine(o, &then_st, refine.then_scalar, refine.then_container);
    if (o.tokenInNode(then_node)) return try analyzeNode(o, then_node, &then_st);
    const then_flow = try analyzeNode(o, then_node, &then_st);

    var else_st = try st.clone(o.gpa);
    defer else_st.deinit(o.gpa);
    try applyRefine(o, &else_st, refine.else_scalar, refine.else_container);
    var else_flow: Flow = .{};
    if (else_opt) |else_node| {
        if (o.tokenInNode(else_node)) return try analyzeNode(o, else_node, &else_st);
        else_flow = try analyzeNode(o, else_node, &else_st);
    }

    if (then_flow.diverged and else_flow.diverged) {
        return .{ .diverged = true };
    } else if (then_flow.diverged) {
        try st.replaceWith(o.gpa, &else_st);
    } else if (else_flow.diverged) {
        try st.replaceWith(o.gpa, &then_st);
    } else {
        then_st.intersectWith(&else_st);
        try st.replaceWith(o.gpa, &then_st);
    }
    return .{};
}

const LoopKind = enum { while_, for_ };

fn analyzeLoop(o: *Oracle, node: Ast.Node.Index, st: *State, kind: LoopKind) error{OutOfMemory}!Flow {
    const tree = o.tree;
    // Conservative: drop facts for anything mutated in the loop body (a use's
    // value could come from any iteration).  No fixpoint in v1.
    dropLoopMutated(o, node, st);

    const body_node: ?Ast.Node.Index = switch (kind) {
        .while_ => if (tree.fullWhile(node)) |w| w.ast.then_expr else null,
        .for_ => if (tree.fullFor(node)) |f| f.ast.then_expr else null,
    };
    const cond_node: ?Ast.Node.Index = switch (kind) {
        .while_ => if (tree.fullWhile(node)) |w| w.ast.cond_expr else null,
        .for_ => null,
    };
    if (cond_node) |c| if (o.tokenInNode(c)) return .{ .answer = o.answerAt(st) };
    if (body_node) |b| {
        if (o.tokenInNode(b)) {
            var body_st = try st.clone(o.gpa);
            defer body_st.deinit(o.gpa);
            if (cond_node) |c| {
                var refine: Refinement = .{};
                collectRefinement(o, c, &refine);
                try applyRefine(o, &body_st, refine.then_scalar, refine.then_container);
            }
            return try analyzeNode(o, b, &body_st);
        }
    }
    return .{};
}

fn applyRefine(o: *Oracle, st: *State, scalar: ?[]const u8, container: ?[]const u8) error{OutOfMemory}!void {
    if (scalar) |s| {
        try st.scalars.add(o.gpa, s);
        // Propagate via `const s = c.len`: s != 0 ⟹ c non-empty.
        for (st.aliases.items) |a| {
            if (std.mem.eql(u8, a.scalar, s)) try st.containers.add(o.gpa, a.container);
        }
        // Propagate via `const s = MINUEND - SUBTRAHEND`: s != 0 and
        // SUBTRAHEND >= 0 (provably) ⟹ MINUEND > SUBTRAHEND >= 0 ⟹ MINUEND >= 1.
        // Sound when operandProvablyNonneg(sub_node): literal, .len field, or
        // ZLS-confirmed unsigned type.  Identifier subtrahends (e.g. `range.start`)
        // require ZLS; without it, the propagation is silently skipped.
        for (st.diff_aliases.items) |da| {
            if (!std.mem.eql(u8, da.diff, s)) continue;
            if (operandProvablyNonneg(o, da.sub_node)) {
                try st.scalars.add(o.gpa, da.minuend);
            }
        }
    }
    if (container) |c| {
        try st.containers.add(o.gpa, c);
        // c non-empty ⟹ any snapshot `s = c.len` is != 0.
        for (st.aliases.items) |a| {
            if (std.mem.eql(u8, a.container, c)) try st.scalars.add(o.gpa, a.scalar);
        }
    }
}

const Refinement = struct {
    then_scalar: ?[]const u8 = null,
    else_scalar: ?[]const u8 = null,
    then_container: ?[]const u8 = null,
    else_container: ?[]const u8 = null,
};

/// Parse a condition for nonzero-scalar / non-empty-container refinements.
fn collectRefinement(o: *Oracle, cond: Ast.Node.Index, out: *Refinement) void {
    if (!o.spend()) return;
    const tree = o.tree;
    const tag = tree.nodeTag(cond);
    if (tag == .bool_and) {
        // `(A) and (B)` true ⟹ both A and B ⟹ union of their THEN-refinements.
        const d = tree.nodeData(cond).node_and_node;
        var a: Refinement = .{};
        var b: Refinement = .{};
        collectRefinement(o, d[0], &a);
        collectRefinement(o, d[1], &b);
        if (out.then_scalar == null) out.then_scalar = a.then_scalar orelse b.then_scalar;
        if (out.then_container == null) out.then_container = a.then_container orelse b.then_container;
        return;
    }
    if (tag == .bool_or) {
        // `(A) or (B)` false ⟹ !A and !B ⟹ union of their ELSE-refinements.
        // This is the canonical early-return-on-empty guard:
        //   if (c.len == 0 or c.empty()) return;   // fall-through ⟹ c non-empty
        const d = tree.nodeData(cond).node_and_node;
        var a: Refinement = .{};
        var b: Refinement = .{};
        collectRefinement(o, d[0], &a);
        collectRefinement(o, d[1], &b);
        if (out.else_scalar == null) out.else_scalar = a.else_scalar orelse b.else_scalar;
        if (out.else_container == null) out.else_container = a.else_container orelse b.else_container;
        return;
    }
    const cmp: Cmp = switch (tag) {
        .greater_than => .gt,
        .less_than => .lt,
        .greater_or_equal => .ge,
        .less_or_equal => .le,
        .bang_equal => .ne,
        .equal_equal => .eq,
        else => return,
    };
    const d = tree.nodeData(cond).node_and_node;
    // Determine (operand, literal) orientation.
    const lhs_key = operandKey(o, d[0]);
    const rhs_key = operandKey(o, d[1]);
    if (lhs_key) |lk| {
        if (isIntLiteralValue(tree, d[1], 0)) applyCmp(out, lk, cmp, 0, false);
        if (isIntLiteralValue(tree, d[1], 1)) applyCmp(out, lk, cmp, 1, false);
        if (intLiteralVal(tree, d[1])) |v| if (v >= 2) applyCmp(out, lk, cmp, v, false);
        // GENERALIZED strict lower bound: `key > X` where X is provably >= 0
        // (non-negative literal, a `.len`, or an UNSIGNED-typed operand per the
        // type engine).  Then `key > X >= 0` implies `key >= 1` in the THEN arm.
        // Zig permits mixed-sign comparison, so a possibly-negative X would make
        // this unsound — hence the non-negativity check.  Covers the shift-loop
        // idiom `while (j > i + 1) : (j -= 1) arr[j] = arr[j-1]` (i unsigned).
        if (cmp == .gt and operandProvablyNonneg(o, d[1])) setThenNonzero(out, lk);
    } else if (rhs_key) |rk| {
        // literal on the left → flip orientation
        if (isIntLiteralValue(tree, d[0], 0)) applyCmp(out, rk, cmp, 0, true);
        if (isIntLiteralValue(tree, d[0], 1)) applyCmp(out, rk, cmp, 1, true);
        if (intLiteralVal(tree, d[0])) |v| if (v >= 2) applyCmp(out, rk, cmp, v, true);
        // `X < key`  ⟺  `key > X`  → key >= 1 in the THEN arm (X provably >= 0).
        if (cmp == .lt and operandProvablyNonneg(o, d[0])) setThenNonzero(out, rk);
    }
}

const Cmp = enum { gt, lt, ge, le, ne, eq };

const OperandKey = struct { key: []const u8, is_container: bool };

/// True iff `node` (a comparison operand) is provably >= 0, so that
/// `key > node` soundly implies `key >= 1`:
///   - a bare number literal (the AST represents `-5` as a negation node, so a
///     `.number_literal` is always non-negative);
///   - a `.len` field access (slice/array length is always >= 0);
///   - an integer expression the type engine resolves to an UNSIGNED type.
fn operandProvablyNonneg(o: *Oracle, node: Ast.Node.Index) bool {
    const tree = o.tree;
    if (tree.nodeTag(node) == .number_literal) return true;
    if (lenContainerPath(o, node) != null) return true;
    if (o.cache) |c| {
        if (c.intInfoOf(node)) |info| return !info.signed;
    }
    return false;
}

/// Record that `ok` is nonzero / non-empty in the THEN arm.
fn setThenNonzero(out: *Refinement, ok: OperandKey) void {
    if (ok.is_container) {
        if (out.then_container == null) out.then_container = ok.key;
    } else if (out.then_scalar == null) out.then_scalar = ok.key;
}

/// Classify a comparison operand as either a scalar local `x` or a container
/// length `c.len` (→ container key = source spelling of `c`).
fn operandKey(o: *Oracle, node: Ast.Node.Index) ?OperandKey {
    const tree = o.tree;
    if (identName(tree, node)) |name| return .{ .key = name, .is_container = false };
    if (lenContainerPath(o, node)) |c| return .{ .key = c, .is_container = true };
    return null;
}

/// If `node` is `<c>.len`, return the source spelling of `<c>`; else null.
fn lenContainerPath(o: *Oracle, node: Ast.Node.Index) ?[]const u8 {
    const tree = o.tree;
    if (tree.nodeTag(node) != .field_access) return null;
    const data = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(data[1]), "len")) return null;
    return nodeSrc(tree, data[0]);
}

/// Apply a comparison `key <cmp> lit` (or flipped) to a refinement.  Encodes
/// the nonzero/non-empty truth of each arm.  `flipped` means literal was on
/// the left (`lit <cmp> key`).
fn applyCmp(out: *Refinement, ok: OperandKey, cmp: Cmp, lit: u64, flipped: bool) void {
    // Normalize to `key OP lit`.
    const op: Cmp = if (!flipped) cmp else switch (cmp) {
        .gt => .lt,
        .lt => .gt,
        .ge => .le,
        .le => .ge,
        .ne => .ne,
        .eq => .eq,
    };
    // Determine which arm proves "key is nonzero / nonempty".
    // Positive (then) facts and negative (else) facts:
    var then_true = false; // key>0 holds in THEN
    var else_true = false; // key>0 holds in ELSE
    if (lit == 0) {
        switch (op) {
            .gt, .ne => then_true = true, // key > 0 / key != 0
            .eq, .le => else_true = true, // key == 0 / key <= 0  ⟹ else: key > 0
            else => {},
        }
    } else if (lit == 1) {
        switch (op) {
            .ge => then_true = true, // key >= 1
            .lt => else_true = true, // key < 1 ⟹ key == 0 ⟹ else: key > 0
            else => {},
        }
    } else { // lit >= 2
        switch (op) {
            // then arm: key >= lit >= 2 >= 1
            .ge, .gt, .eq => then_true = true,
            // else arm: key >= lit >= 2 >= 1 (from `key < lit` or `key <= lit` diverging)
            .lt, .le => else_true = true,
            else => {},
        }
    }
    if (then_true) {
        if (ok.is_container) {
            if (out.then_container == null) out.then_container = ok.key;
        } else if (out.then_scalar == null) out.then_scalar = ok.key;
    }
    if (else_true) {
        if (ok.is_container) {
            if (out.else_container == null) out.else_container = ok.key;
        } else if (out.else_scalar == null) out.else_scalar = ok.key;
    }
}

/// Drop container facts whose root path is mutated within `node`'s tokens.
fn killMutatedContainers(o: *Oracle, node: Ast.Node.Index, st: *State) void {
    if (st.containers.keys.items.len == 0 and st.aliases.items.len == 0) return;
    const tree = o.tree;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    dropContainersMutatedInTokens(tree, first, last, st);
}

fn dropLoopMutated(o: *Oracle, loop_node: Ast.Node.Index, st: *State) void {
    const tree = o.tree;
    const first = tree.firstToken(loop_node);
    const last = tree.lastToken(loop_node);
    const tags = tree.tokens.items(.tag);
    // Scalars: any `NAME <assign-op>` inside the loop.
    var t = first;
    while (t < last) : (t += 1) {
        if (tags[t] != .identifier) continue;
        if (isAssignOp(tags[t + 1])) st.scalars.remove(tree.tokenSlice(t));
    }
    dropContainersMutatedInTokens(tree, first, last, st);
}

/// Mutating container methods (grow/shrink/clear).
fn isMutatingMethod(name: []const u8) bool {
    const muts = [_][]const u8{
        "append",      "appendSlice",        "appendAssumeCapacity", "appendNTimes",
        "insert",      "insertSlice",        "resize",               "shrinkAndFree",
        "shrinkRetainingCapacity",          "clearRetainingCapacity", "clearAndFree",
        "pop",         "popOrNull",          "orderedRemove",        "swapRemove",
        "addOne",      "addOneAssumeCapacity", "addManyAsArray",     "addManyAsSlice",
        "ensureTotalCapacity",              "ensureUnusedCapacity", "writer",
        "deinit",      "toOwnedSlice",
    };
    for (muts) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

/// For each tracked container path, drop it if the token range mutates it:
/// `<path> . <mutating-method> (` or `<path> <assign-op>` or `<path> . X =`.
fn dropContainersMutatedInTokens(
    tree: *const Ast,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    st: *State,
) void {
    if (st.containers.keys.items.len == 0 and st.aliases.items.len == 0) return;
    const tags = tree.tokens.items(.tag);
    var i: usize = 0;
    while (i < st.containers.keys.items.len) {
        const path = st.containers.keys.items[i];
        if (containerMutatedInTokens(tree, tags, first, last, path)) {
            _ = st.containers.keys.swapRemove(i);
        } else i += 1;
    }
    // A mutated container also stales any `n = c.len` length snapshot.
    var ai: usize = 0;
    while (ai < st.aliases.items.len) {
        if (containerMutatedInTokens(tree, tags, first, last, st.aliases.items[ai].container)) {
            _ = st.aliases.swapRemove(ai);
        } else ai += 1;
    }
}

/// True iff `path` (a source spelling like "arr" or "self.items") is mutated
/// in [first,last]: a call `path.<mut>(`, `path <assign>`, or `path.<f> =`.
fn containerMutatedInTokens(
    tree: *const Ast,
    tags: []const std.zig.Token.Tag,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    path: []const u8,
) bool {
    var t = first;
    while (t + 1 <= last) : (t += 1) {
        // Match the path as a contiguous source run beginning at token t.
        const after = matchPathTokens(tree, t, last, path) orelse continue;
        // after = token index just past the matched path.
        if (after > last) return false;
        switch (tags[after]) {
            .period => {
                // path.<ident>(  → method call; treat as mutation if the
                // method is mutating, OR `path.<ident> =` (field write).
                if (after + 1 <= last and tags[after + 1] == .identifier) {
                    const m = tree.tokenSlice(after + 1);
                    if (after + 2 <= last and tags[after + 2] == .l_paren and isMutatingMethod(m)) return true;
                    if (after + 2 <= last and isAssignOp(tags[after + 2])) return true;
                }
            },
            else => if (isAssignOp(tags[after])) return true,
        }
    }
    return false;
}

/// If the source spelling `path` matches the contiguous token run starting at
/// `t`, return the token index just past it; else null.  Handles dotted paths
/// like "self.items" (identifier period identifier).
fn matchPathTokens(tree: *const Ast, t: Ast.TokenIndex, last: Ast.TokenIndex, path: []const u8) ?Ast.TokenIndex {
    var cur = t;
    var rest = path;
    while (rest.len > 0) {
        if (cur > last) return null;
        if (tree.tokens.items(.tag)[cur] == .identifier) {
            const slice = tree.tokenSlice(cur);
            if (!std.mem.startsWith(u8, rest, slice)) return null;
            rest = rest[slice.len..];
            cur += 1;
        } else if (rest[0] == '.') {
            if (tree.tokens.items(.tag)[cur] != .period) return null;
            rest = rest[1..];
            cur += 1;
        } else return null;
    }
    return cur;
}

fn dropContainersRootedAt(st: *State, root: []const u8) void {
    var i: usize = 0;
    while (i < st.containers.keys.items.len) {
        const p = st.containers.keys.items[i];
        // root match: p == root, or p starts with `root.`
        const rooted = std.mem.eql(u8, p, root) or
            (p.len > root.len and std.mem.startsWith(u8, p, root) and p[root.len] == '.');
        if (rooted) _ = st.containers.keys.swapRemove(i) else i += 1;
    }
}

// ── small AST predicates ────────────────────────────────────

fn identName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .identifier) return null;
    return tree.tokenSlice(tree.nodeMainToken(node));
}

fn isAssignOp(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .plus_percent_equal,
        .minus_percent_equal,
        => true,
        else => false,
    };
}

fn isPositiveIntLiteral(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .number_literal) return false;
    const v = std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch return false;
    return v > 0;
}

fn isIntLiteralValue(tree: *const Ast, node: Ast.Node.Index, want: u64) bool {
    if (tree.nodeTag(node) != .number_literal) return false;
    const v = std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch return false;
    return v == want;
}

/// Returns the unsigned value of a number-literal node, or null if not a literal.
fn intLiteralVal(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch null;
}

/// Source substring spanning a node (for canonical container-path keys).
fn nodeSrc(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const starts = tree.tokens.items(.start);
    const ft = tree.firstToken(node);
    const lt = tree.lastToken(node);
    const start: usize = starts[ft];
    const end: usize = starts[lt] + tree.tokenSlice(lt).len;
    return tree.source[start..end];
}

fn blockStmts(
    tree: *const Ast,
    block_node: Ast.Node.Index,
    buf: *[2]Ast.Node.Index,
) []const Ast.Node.Index {
    return switch (tree.nodeTag(block_node)) {
        .block, .block_semicolon => tree.extraDataSlice(tree.nodeData(block_node).extra_range, Ast.Node.Index),
        .block_two, .block_two_semicolon => blk: {
            const data = tree.nodeData(block_node);
            buf[0] = data.opt_node_and_opt_node[0].unwrap() orelse break :blk &.{};
            if (data.opt_node_and_opt_node[1].unwrap()) |second| {
                buf[1] = second;
                break :blk buf[0..2];
            }
            break :blk buf[0..1];
        },
        else => &.{},
    };
}

test {
    _ = @import("value_range_tests.zig");
}
