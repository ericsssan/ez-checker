//! Checker — single-file type inference over a parsed Ast.
//!
//! Computes a TypeId for every expression node, lazily.  Resolves
//! identifier references via the semantic table to find a declared
//! type annotation (declarator → ts_type_annotation, function param
//! type, return type), then propagates through the local expression
//! tree.  Anything we can't resolve becomes `any` — this is the same
//! "unknown source ⇒ any" assumption that typescript-eslint makes
//! when noImplicitAny is off, and it gives the unsafe-* rules their
//! correct behavior: `JSON.parse(...)` returns `any`, so assigning
//! it to a typed target fires.

const std = @import("std");
const parser = @import("es_parser");
const ast = parser.ast;
const symbol_mod = parser.symbol;
const Ast = ast.Ast;
const NodeIndex = ast.NodeIndex;
const TokenIndex = ast.TokenIndex;
const SubRange = ast.SubRange;
const SemanticResult = parser.semantic.SemanticResult;

const tymod = @import("types.zig");
const TypeStore = tymod.TypeStore;
const TypeId = tymod.TypeId;
const Type = tymod.Type;
pub const EnumKind = enum(u8) { number, string, mixed };

/// CFG sentinel for "no segment" (mirrors code_path.NONE_SEG).
const NONE_SEG: u32 = std.math.maxInt(u32);

/// A write to an evolving-any binding: the assigned RHS expression, the
/// enclosing assignment node, the assignment operator (`.assign` for `=`, or a
/// compound `*_assign`), the CFG segment it occurs in, and the source offset of
/// the assignment target.  A write does not reach a read that lies inside its
/// own assignment subtree (the read is evaluating this write's value).
const EvolvingWrite = struct { rhs: NodeIndex, assign: NodeIndex, op: ast.Node.Tag, seg: u32, pos: u32 };

/// TypeScript compiler options that affect type inference and display.
/// Passed to Checker.init; defaults represent a vanilla tsconfig.json with
/// no explicit settings (non-strict, ES5 target, no special module mode).
pub const CheckerOpts = struct {
    strict_null_checks: bool = false,
    no_implicit_any: bool = false,
    use_define_for_class_fields: bool = false,
    /// True when the source file explicitly declares `// @strict: false`.
    /// In that legacy mode TypeScript types empty arrays as `undefined[]`
    /// rather than `never[]`.
    strict_explicitly_false: bool = false,
    /// True when JSX is checked in a React-style mode (`jsx: react` /
    /// `react-jsx` / `react-jsxdev` / `react-native`).  Under these modes a
    /// JSX element expression has type `JSX.Element`; under `preserve` / unset
    /// it stays `any`.
    jsx_react_mode: bool = false,
    /// True for `.js`/`.jsx` source files, where JSDoc `@param`/`@type`/
    /// `@returns` annotations supply types (in `.ts` they're ignored).
    is_js_file: bool = false,
    /// File names of sibling modules concatenated into this AST (multi-file
    /// test sources).  An import whose specifier matches one of these can be
    /// resolved by bare-name lookup in the combined AST; others are external
    /// and stay `any`.
    available_modules: []const []const u8 = &.{},
    target: Target = .es5,
    /// Module resolution strategy.  Affects import resolution rules —
    /// notably, node16/nodenext require explicit .js/.mjs/.cjs extensions
    /// on relative imports; without them the import is unresolvable → `any`.
    module: Module = .none,

    pub const Target = enum {
        es5, es2015, es2016, es2017, es2018, es2019,
        es2020, es2021, es2022, es2023, esnext,
    };
    pub const Module = enum {
        commonjs, amd, system, umd,
        es2015, es2020, es2022, esnext,
        node16, node18, node20, nodenext,
        none,
    };

    pub fn isNode16Style(self: CheckerOpts) bool {
        return self.module == .node16 or self.module == .node18 or
            self.module == .node20 or self.module == .nodenext;
    }
};

/// Opaque interface for cross-file module resolution.
/// The concrete implementation (ModuleCache) lives outside this library.
pub const ModuleResolver = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (
        ctx: *anyopaque,
        from_dir: []const u8,
        module_spec: []const u8,
        export_name: []const u8,
        local_store: *TypeStore,
        gpa: std.mem.Allocator,
    ) ?TypeId,

    pub fn resolveExportedType(
        self: ModuleResolver,
        from_dir: []const u8,
        module_spec: []const u8,
        export_name: []const u8,
        local_store: *TypeStore,
        gpa: std.mem.Allocator,
    ) ?TypeId {
        return self.resolve_fn(self.ctx, from_dir, module_spec, export_name, local_store, gpa);
    }
};

/// Describes where an imported name came from.
pub const ImportEntry = struct {
    /// Module specifier as written in source (e.g. "./foo" or "@pkg/bar").
    module_specifier: []const u8,
    /// The name exported from the source module (may differ when `import { A as B }`).
    exported_name: []const u8,
};

/// Returns true when a module specifier is a relative path that lacks an explicit
/// node-resolution extension (.js/.mjs/.cjs/.ts/.tsx/.mts/.cts).
/// In node16/nodenext mode tsc requires the extension; omitting it means the
/// module is unresolvable, so tsc types the namespace binding as `any`.
fn node16UnresolvableSpec(spec: []const u8) bool {
    if (!std.mem.startsWith(u8, spec, "./") and !std.mem.startsWith(u8, spec, "../")) return false;
    const exts = [_][]const u8{ ".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts" };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, spec, ext)) return false;
    }
    return true;
}

const ExpandoProp = struct { name: []const u8, value: NodeIndex };
const JsdocParam = struct { name: []const u8, type_str: []const u8 };

pub const Checker = struct {
    gpa: std.mem.Allocator,
    ast_ref: *const Ast,
    semantic: *const SemanticResult,
    store: TypeStore,
    /// node → TypeId cache (lazy; .none means "not yet computed").
    node_types: []TypeId,
    /// sym → declared TypeId (lazy).
    sym_types: []TypeId,
    /// identifier node index → resolved SymbolId (0xFFFFFFFF = none).  Built
    /// once at init from the reference table so identifier inference is O(1).
    node_to_sym: []u32,
    /// Set of type-name identifiers declared in the file (interfaces,
    /// type aliases, classes, enums, type params, imports).  A type
    /// reference to a name NOT in this set AND NOT a built-in resolves
    /// to `error_t` — TSe's "intrinsic error type" condition.
    known_type_names: std.StringHashMapUnmanaged(void),

    /// Maps type names to their AST declaration node so `resolveTypeRef`
    /// can build the structural type on demand.  Filled at init time
    /// for interfaces and classes — type aliases use the same mechanism
    /// when their RHS is a structural type.
    type_decl_nodes: std.StringHashMapUnmanaged(NodeIndex),

    /// Flat index of every `ts_type_parameter` node in the file, collected
    /// once during `buildKnownTypeNames`.  Generic-parameter resolution
    /// (`resolveTypeParameterConstraint` / `findTypeParameterDecl`) iterates
    /// this list — typically a few hundred entries — instead of re-scanning
    /// all N AST nodes per type-reference, which was O(queries × nodes) on
    /// generic-dense code.
    type_param_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty,

    /// Bounded stack of class decls currently inside `buildClassInstanceType`.
    /// Breaks `this`-type / inheritance recursion: a re-entrant build of a
    /// class already on the stack resolves to a cheap `type_ref` placeholder
    /// instead of rebuilding the class. Without this, `this` in a class method
    /// rebuilds the whole class on every resolution — unboundedly, and
    /// *exponentially* when a method has both a `this` param and `this` return.
    building_classes: [32]NodeIndex = undefined,
    building_n: u8 = 0,

    /// Bounded stack of names currently being resolved by `resolveTypeofType`.
    /// Breaks `typeof`-recursion: `declare function f(): typeof f` and its
    /// overloaded/mutually-recursive cousins reference their own value type,
    /// which rebuilds the same function type — unboundedly without this guard.
    typeof_names: [32][]const u8 = undefined,
    typeof_n: u8 = 0,

    /// Bounded stack of type-parameter names currently being resolved by
    /// `resolveTypeParameterConstraint`. Breaks self-referential constraints
    /// like `<T extends null extends T ? any : never>`, where resolving T's
    /// constraint resolves T, which resolves its constraint again.
    tparam_names: [32][]const u8 = undefined,
    tparam_n: u8 = 0,

    /// Index: declaration name → `declarator` / `fn_decl`-family nodes that
    /// bind it, in node order.  Built once during `buildKnownTypeNames`.
    /// The by-name lookups on the call path (`findCalleeFnDecl`,
    /// `functionTypeFromAllOverloads`, `typeOfNameByAstSearch`,
    /// `constInitIsSymbolCall`) iterate the matching list instead of
    /// re-scanning all N nodes per call — was O(calls × nodes) on
    /// declaration-dense code.
    value_decl_by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(NodeIndex)) = .empty,

    /// Function names that have property assignments on them (`foo.x = 1`)
    /// outside the function body — expando functions.  tsc types these as
    /// `typeof foo` in value position, not the raw function type.  Each entry
    /// records the assigned property names with their value nodes so that
    /// `foo.x` member access can resolve lazily to the widened value type.
    expando_fns: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ExpandoProp)) = .empty,

    /// Names declared `var X = {}` (JS) that receive later `X.prop = …`
    /// assignments — salsa expando objects; tsc types them `typeof X`.
    /// Their props live in `expando_fns` alongside function expandos.
    expando_objs: std.StringHashMapUnmanaged(void) = .empty,

    /// True when the file contains `module.exports = { … }` (object-literal
    /// RHS) — only then does tsc display `typeof module.exports`.
    module_exports_literal: bool = false,

    /// Lazily-built map: destructuring pattern node → its `ts_type_annotation`
    /// node.  Patterns store their `: T` annotation as a child node parented to
    /// the pattern (not in the pattern's lhs/rhs range), so this reverse index
    /// lets `({ a }: T)` parameter bindings find their declared type.
    pattern_annotations: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    pattern_annotations_built: bool = false,

    /// JSDoc type annotations harvested from `/** … */` comment blocks (JS
    /// files use these in place of TS type syntax).  Lazily built from the
    /// source text.  `jsdoc_params` maps a function node to its ordered
    /// `@param` type strings; `jsdoc_returns` its `@returns` type; `jsdoc_vars`
    /// maps a declarator node to its `@type`.  Type strings are slices into the
    /// source (no allocation).
    jsdoc_params: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(JsdocParam)) = .empty,
    jsdoc_returns: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    jsdoc_vars: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    jsdoc_built: bool = false,

    /// Cache: type name → resolved TypeId for declared structural types.
    /// Populated lazily by `resolveDeclaredType`.  Recursion-safe via a
    /// sentinel (ID_UNKNOWN inserted before recursion, replaced after).
    declared_type_cache: std.StringHashMapUnmanaged(TypeId),

    /// Per-enum classification: number-valued or string-valued.  TS infers
    /// each enum as one or the other based on whether ANY member has a
    /// string initializer.  Used by no-mixed-enums and no-unsafe-enum-
    /// comparison.  Populated by `buildKnownTypeNames`.
    enum_kinds: std.StringHashMapUnmanaged(EnumKind),

    /// Built-in global *values* (`console`, `Math`, `JSON`, ...).  Maps
    /// the identifier name → structural TypeId.  Acts as a minimal
    /// stand-in for the lib.d.ts shapes TSC loads at startup.  When
    /// `inferIdentifier` can't find a local symbol or AST declaration
    /// it falls back to this map — letting `console.log()` resolve to
    /// `void` without modelling the full Window / globalThis chain.
    global_value_types: std.StringHashMapUnmanaged(TypeId),

    /// Set of TypeIds whose methods are "natively bound" — i.e. don't
    /// depend on `this` and are always safe to call unbound.  Populated
    /// during `buildGlobalValueTypes` for Math, JSON, etc.
    natively_bound_type_ids: std.AutoHashMapUnmanaged(TypeId, void),

    /// Maps local binding name → (module_specifier, exported_name) for
    /// each named import in the file.  Populated by `buildKnownTypeNames`.
    /// Used by `resolveDeclaredType` to look up cross-file types when a
    /// name isn't declared locally.
    import_map: std.StringHashMapUnmanaged(ImportEntry) = .empty,

    /// Maps `import * as NS` local binding name → module_specifier.
    /// Used by `inferMemberOnNamespace` to resolve `NS.Member` lookups
    /// through the module's exported types.
    namespace_import_map: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Evolving-any support.  An untyped `var`/`let` (no annotation, no
    /// initializer) is typed at each *use* as the union of the assigned
    /// values that reach that use in the control-flow graph — reaching
    /// definitions over the CFG segment graph the parser already builds
    /// (`code_path_result`), with each write's segment recovered from the
    /// reference table's `seg_id` column.
    evolving_assign_index: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(EvolvingWrite)) = .empty,
    evolving_index_built: bool = false,
    /// Symbols whose evolving type is mid-computation — guards self-reference
    /// (`a = a + 1`).
    evolving_in_progress: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// node → CFG segment id (NONE_SEG = none), built once with the index.
    node_seg: []u32 = &.{},
    /// Reusable scratch for the per-use backward reachability walk.
    seg_reach_set: std.AutoHashMapUnmanaged(u32, void) = .empty,
    seg_worklist: std.ArrayListUnmanaged(u32) = .empty,

    /// Evolving-array support (`let x = []` / `let x; x = []`).  TypeScript's
    /// auto-array type: the element type grows from `x.push(v)` and `x[i] = v`
    /// contributions.  Symbols flagged here are evolving arrays; the element
    /// contributions reaching a pure read give its `(union)[]` type, while a
    /// push-receiver / element-assign-target reads as `any[]`.
    evolving_array_syms: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Symbols disqualified from evolving-array (assigned a non-empty array
    /// literal) — order-independent guard during index building.
    evolving_array_disq: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Symbols whose declarator initializer is `[]` (auto-array from the
    /// declaration onward, so every use is an array).
    evolving_array_init: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The `x = []` reset writes (seg/pos) that establish the auto-array; a use
    /// is only an array if one reaches it.
    evolving_array_resets: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(EvolvingWrite)) = .empty,
    evolving_array_contribs: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(EvolvingWrite)) = .empty,

    /// Absolute path of the file being checked.  Empty string means
    /// cross-file resolution is disabled.
    file_path: []const u8 = "",

    /// Optional cross-file module resolver.
    /// Null when cross-file resolution is disabled (file_path is empty).
    module_resolver: ?ModuleResolver = null,

    /// Additional interface declaration nodes for declaration merging.
    /// When the same interface name appears more than once, extra declarations
    /// (beyond the first in type_decl_nodes) are collected here so
    /// buildInterfaceType can merge their members.
    merged_iface_extra: std.ArrayListUnmanaged(struct { name: []const u8, node: NodeIndex }) = .empty,

    /// Additional namespace/module declaration nodes for declaration merging.
    /// Same pattern as merged_iface_extra but for namespace blocks.
    merged_ns_extra: std.ArrayListUnmanaged(struct { name: []const u8, node: NodeIndex }) = .empty,

    /// Maps generic function TypeId → rendered type-parameter prefix string
    /// (e.g. `"<T>"`, `"<K, V>"`).  Populated lazily when a generic function or
    /// method type is built; looked up by typeToStringInner to emit the correct
    /// `<T>(…) => …` form that tsc produces.  First writer wins for interned types.
    fn_type_params: std.AutoHashMapUnmanaged(TypeId, []const u8) = .empty,

    /// Function types that were built from explicit overload declarations (no-body
    /// signatures).  These render as `{ (p): T; }` object form even when they have
    /// only one signature, matching TypeScript's display for overloaded functions.
    overload_fn_types: std.AutoHashMapUnmanaged(TypeId, void) = .empty,

    /// Per-signature type params prefix (e.g. `"<T>"`) keyed by signature pool
    /// index.  Used for multi-signature function types where each overload can
    /// have its own type parameters.  Looked up by typeToStringInner when
    /// rendering `{ <T>(…): R; <U>(…): R; }` overload sets.
    sig_type_params: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    /// Temporary type-param rename table used during multi-sig overload rendering.
    /// Maps original param name → display name (e.g. "T" → "T_1").
    /// Set/cleared per-sig inside typeToStringInner; read by .type_param rendering.
    tp_renames: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Recursion counter for resolveConditionalTypeWithSubst / distributeConditional.
    /// Prevents stack overflow on deeply nested generic conditional types.
    /// Pool of dynamically-allocated strings (e.g. qualified type names like
    /// "lavali.xanthognathus").  Freed all at once in deinit.
    string_pool: std.ArrayListUnmanaged([]u8) = .empty,

    subst_depth: u8 = 0,

    /// Recursion guard for buildTypeParam → resolveTypeNodeParamAware → buildTypeParam
    /// (constraint chains like `V extends T`, and self-referential ones such as
    /// `T extends Array<T>`).
    tp_depth: u8 = 0,

    /// General type-node resolution depth guard.  Recursive generic declarations
    /// (e.g. bluebird's `then<U>(…): Bluebird<U>` over `type Resolvable<R> = R |
    /// PromiseLike<R>`) can drive resolveTypeNode arbitrarily deep — especially
    /// once type parameters resolve to genuine `.type_param`s that get
    /// substituted through alias bodies.  The name-keyed declared-type sentinel
    /// breaks *named* cycles, but not parametric-instantiation chains; this caps
    /// total depth and bails to `unknown` (a safe leaf) before the native stack
    /// overflows.  The cap is far above any real annotation's nesting.
    resolve_depth: u16 = 0,
    /// When > 0, resolveTypeRef returns type_param TypeIds for in-scope type parameters
    /// instead of resolving to their constraints.  Set during resolveFunctionType so
    /// ts_function_type params and return types display as `T` rather than `any`.
    type_pos_depth: u8 = 0,

    /// Compiler options that affect type inference.
    checker_opts: CheckerOpts = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        ast_ref: *const Ast,
        semantic: *const SemanticResult,
        opts: CheckerOpts,
    ) !Checker {
        const node_count = ast_ref.nodes.len;
        const node_types = try gpa.alloc(TypeId, node_count);
        @memset(node_types, TypeId.none);
        const sym_count = semantic.symbols.list.len;
        const sym_types = try gpa.alloc(TypeId, sym_count);
        @memset(sym_types, TypeId.none);
        // Reverse index: identifier node → resolved SymbolId, built once from
        // the reference table.  Replaces `symbolForIdentRef`'s O(refs) linear
        // scan (run per identifier inference) with an O(1) lookup.  Sentinel
        // 0xFFFFFFFF = no resolved symbol for that node.
        const node_to_sym = try gpa.alloc(u32, node_count);
        @memset(node_to_sym, 0xFFFFFFFF);
        {
            const refs = &semantic.references;
            const ref_total = refs.count();
            var ri: u32 = 0;
            while (ri < ref_total) : (ri += 1) {
                const rid = parser.reference.ReferenceId.fromInt(ri);
                if (!refs.isResolved(rid)) continue;
                const ni = refs.getNode(rid).toInt();
                if (ni < node_count) node_to_sym[ni] = refs.getSymbol(rid).toInt();
            }
        }
        var self: Checker = .{
            .gpa = gpa,
            .ast_ref = ast_ref,
            .semantic = semantic,
            .store = try TypeStore.init(gpa),
            .node_types = node_types,
            .sym_types = sym_types,
            .node_to_sym = node_to_sym,
            .known_type_names = .empty,
            .type_decl_nodes = .empty,
            .declared_type_cache = .empty,
            .enum_kinds = .empty,
            .global_value_types = .empty,
            .natively_bound_type_ids = .empty,
            .checker_opts = opts,
        };
        try self.buildKnownTypeNames();
        try self.buildGlobalValueTypes();
        return self;
    }

    pub fn deinit(self: *Checker) void {
        for (self.string_pool.items) |s| self.gpa.free(s);
        self.string_pool.deinit(self.gpa);
        self.store.deinit();
        self.gpa.free(self.node_types);
        self.gpa.free(self.sym_types);
        self.gpa.free(self.node_to_sym);
        self.type_param_nodes.deinit(self.gpa);
        {
            var vit = self.value_decl_by_name.valueIterator();
            while (vit.next()) |list| list.deinit(self.gpa);
            self.value_decl_by_name.deinit(self.gpa);
        }
        self.known_type_names.deinit(self.gpa);
        self.enum_kinds.deinit(self.gpa);
        {
            var eit = self.expando_fns.valueIterator();
            while (eit.next()) |lst| lst.deinit(self.gpa);
        }
        self.expando_fns.deinit(self.gpa);
        self.expando_objs.deinit(self.gpa);
        self.pattern_annotations.deinit(self.gpa);
        {
            var jit = self.jsdoc_params.valueIterator();
            while (jit.next()) |lst| lst.deinit(self.gpa);
        }
        self.jsdoc_params.deinit(self.gpa);
        self.jsdoc_returns.deinit(self.gpa);
        self.jsdoc_vars.deinit(self.gpa);
        self.type_decl_nodes.deinit(self.gpa);
        self.declared_type_cache.deinit(self.gpa);
        self.global_value_types.deinit(self.gpa);
        self.natively_bound_type_ids.deinit(self.gpa);
        self.import_map.deinit(self.gpa);
        self.namespace_import_map.deinit(self.gpa);
        {
            var eit = self.evolving_assign_index.valueIterator();
            while (eit.next()) |list| list.deinit(self.gpa);
            self.evolving_assign_index.deinit(self.gpa);
        }
        self.evolving_in_progress.deinit(self.gpa);
        if (self.node_seg.len > 0) self.gpa.free(self.node_seg);
        self.seg_reach_set.deinit(self.gpa);
        self.seg_worklist.deinit(self.gpa);
        self.evolving_array_syms.deinit(self.gpa);
        self.evolving_array_disq.deinit(self.gpa);
        self.evolving_array_init.deinit(self.gpa);
        {
            var rit = self.evolving_array_resets.valueIterator();
            while (rit.next()) |list| list.deinit(self.gpa);
            self.evolving_array_resets.deinit(self.gpa);
        }
        {
            var ait = self.evolving_array_contribs.valueIterator();
            while (ait.next()) |list| list.deinit(self.gpa);
            self.evolving_array_contribs.deinit(self.gpa);
        }
        self.merged_iface_extra.deinit(self.gpa);
        self.merged_ns_extra.deinit(self.gpa);
        {
            var it = self.fn_type_params.valueIterator();
            while (it.next()) |v| self.gpa.free(v.*);
            self.fn_type_params.deinit(self.gpa);
        }
        {
            var it = self.sig_type_params.valueIterator();
            while (it.next()) |v| self.gpa.free(v.*);
            self.sig_type_params.deinit(self.gpa);
        }
        self.tp_renames.deinit(self.gpa);
        self.overload_fn_types.deinit(self.gpa);
    }

    // ── Public queries (LintContext-facing) ───────────────

    pub fn typeOf(self: *Checker, node: NodeIndex) TypeId {
        if (node == .none) return tymod.ID_ANY;
        const idx = node.toInt();
        const cached = self.node_types[idx];
        if (!cached.eq(TypeId.none)) return cached;
        // Mark in-progress before recursing so a cyclic expression (e.g.
        // `static bar = A.foo + 1` where resolving `A`'s static side needs
        // `bar`'s type, which needs `A.foo`…) resolves to `unknown` on the
        // back-edge instead of recursing until the stack overflows.
        self.node_types[idx] = tymod.ID_UNKNOWN;
        const computed = self.inferExpr(node);
        // Don't persist results produced while an evolving-any inference is in
        // progress: same-variable reads inside a reaching write's RHS get
        // short-circuited to `any` by the recursion guard, which would poison
        // the cache for their real (later) query.  Leave them uncached so they
        // recompute correctly once the guard clears.  (Order-independence:
        // otherwise a node's type would depend on whether it was first touched
        // during an evolving computation — e.g. the oracle's parent-first
        // full-tree sweep vs a lazy query.)
        if (self.evolving_in_progress.count() == 0) {
            self.node_types[idx] = computed;
        } else {
            self.node_types[idx] = TypeId.none;
        }
        return computed;
    }

    pub fn typeIsAny(self: *Checker, node: NodeIndex) bool {
        return tymod.isAny(&self.store, self.typeOf(node));
    }

    pub fn typeContainsAny(self: *Checker, node: NodeIndex) bool {
        return tymod.containsAny(&self.store, self.typeOf(node));
    }

    // ── Expression inference ──────────────────────────────

    fn inferExpr(self: *Checker, node: NodeIndex) TypeId {
        const t = self.ast_ref.nodeTag(node);
        return switch (t) {
            .string_literal => self.literalString(node),
            .number_literal => self.literalNumber(node),
            .bigint_literal => self.literalBigint(node),
            .boolean_literal => self.literalBoolean(node),
            .null_literal => tymod.ID_NULL,
            .regex_literal => self.regexpRefType(),
            .template_literal => self.inferTemplateLiteral(node),
            .tagged_template => blk: {
                const tag = self.ast_ref.nodeData(node).lhs;
                if (tag == .none) break :blk tymod.ID_UNKNOWN;
                const tag_ty = self.typeOf(tag);
                if (tymod.isAny(&self.store, tag_ty)) break :blk tymod.ID_ANY;
                const tf = self.store.get(tag_ty);
                if (tf.kind == .function_t) {
                    const sigs = self.store.signaturesOf(tf.signatures);
                    if (sigs.len > 0) break :blk sigs[0].return_type;
                }
                break :blk tymod.ID_UNKNOWN;
            },
            .this_expr => self.inferThis(node),
            // `super` types as the base class: instance side in instance
            // members (`super : A`), constructor side in statics (`typeof A`).
            .super_expr => self.inferSuper(node),

            .identifier => self.inferIdentifier(node),
            // A JSX element / fragment expression evaluates to `JSX.Element`
            // (the configured JSX factory's element type — `JSX.Element` for
            // the default React-style factory, which is what tsc's baselines
            // record).  This makes JSX-returning functions type as
            // `() => JSX.Element` rather than `() => any`.
            .jsx_element, .jsx_self_closing, .jsx_fragment => self.jsxElementType(),
            // A JSX element name (`<Foo .../>`) references a value — resolve it
            // like an identifier so the facade can read the component's props.
            .jsx_identifier => self.inferIdentifier(node),
            // Property name in a member access (obj.prop): look up the property
            // on the receiver type.  property_ident has no symbol reference, so
            // skip straight to the parent-based dispatch.
            .property_ident => self.inferPropertyIdent(node),

            .ts_as_expr, .ts_type_assertion => self.inferAsCast(node, t),
            .ts_satisfies_expr => self.inferSatisfies(node),
            .ts_non_null_expr => self.typeOf(self.ast_ref.nodeData(node).lhs),

            .grouping_expr => self.typeOf(self.ast_ref.nodeData(node).lhs),
            .sequence_expr => self.inferSequence(node),
            .conditional => self.inferConditional(node),
            .assign => blk: {
                const ad = self.ast_ref.nodeData(node);
                if (self.checker_opts.is_js_file and ad.lhs != .none and
                    self.ast_ref.nodeTag(ad.lhs) == .member_expr)
                {
                    // CommonJS `module.exports = {…}` evaluates to the exports
                    // object (`typeof module.exports`).
                    if (self.isModuleExportsMember(ad.lhs) and
                        self.isEmptyObjectLiteral(ad.rhs))
                    {
                        break :blk self.typeOf(ad.lhs);
                    }
                    // Salsa expando-prop declaration (`Outer.Inner = function(){}`,
                    // `Host.Metrics = {}`): when the member itself resolves to a
                    // named `typeof X` entity, the assignment displays it too.
                    if (ad.rhs != .none) {
                        switch (self.ast_ref.nodeTag(ad.rhs)) {
                            .fn_expr, .async_fn_expr, .generator_fn_expr,
                            .async_generator_fn_expr, .arrow_fn, .async_arrow_fn,
                            .class_expr, .object_literal => {
                                const lt = self.typeOf(ad.lhs);
                                const ltt = self.store.get(lt);
                                if (ltt.kind == .type_ref and
                                    std.mem.startsWith(u8, ltt.name, "typeof "))
                                {
                                    break :blk lt;
                                }
                            },
                            else => {},
                        }
                    }
                }
                break :blk self.typeOf(ad.rhs);
            },
            // Compound assignments: result is the new value of LHS.  If
            // LHS is any, result is any.  Otherwise approximate based on
            // operator class (most produce number; string/bigint variants
            // would need a more refined check but rarely surface for
            // unsafe-* rules).
            .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign,
            .exp_assign, .and_assign, .or_assign, .xor_assign, .shl_assign,
            .shr_assign, .ushr_assign => blk: {
                const data = self.ast_ref.nodeData(node);
                if (data.lhs == .none or data.rhs == .none) break :blk tymod.ID_ANY;
                const lhs_ty = self.typeOf(data.lhs);
                if (tymod.isAny(&self.store, lhs_ty)) break :blk tymod.ID_ANY;
                const rhs_ty = self.typeOf(data.rhs);
                if (tymod.isAny(&self.store, rhs_ty)) break :blk tymod.ID_ANY;
                break :blk lhs_ty;
            },

            // Logical compound assignments evaluate to the assigned value:
            //   `a ||= b`  ≡  `a || (a = b)`  → truthy-part-of-a  ∪ typeof b
            //   `a &&= b`  ≡  `a && (a = b)`  → falsy-part-of-a   ∪ typeof b
            //   `a ??= b`  ≡  `a ?? (a = b)`  → non-nullish-of-a  ∪ typeof b
            .logical_or_assign, .logical_and_assign, .nullish_assign => blk: {
                const data = self.ast_ref.nodeData(node);
                if (data.lhs == .none or data.rhs == .none) break :blk tymod.ID_ANY;
                const lhs_ty = self.typeOf(data.lhs);
                if (tymod.isAny(&self.store, lhs_ty)) break :blk tymod.ID_ANY;
                const rhs_ty = self.typeOf(data.rhs);
                if (tymod.isAny(&self.store, rhs_ty)) break :blk tymod.ID_ANY;
                const kept = switch (t) {
                    .logical_or_assign => self.narrowTruthy(lhs_ty, false),
                    .logical_and_assign => self.narrowTruthy(lhs_ty, true),
                    .nullish_assign => self.narrowNullish(lhs_ty, true),
                    else => unreachable,
                };
                if (kept.eq(tymod.ID_NEVER)) break :blk rhs_ty;
                if (kept.eq(rhs_ty)) break :blk kept;
                // Display order mirrors evaluation: `||=`/`??=` yield the
                // kept (primary) part first, then the fallback; `&&=` yields
                // the assigned value first, then the retained falsy part.
                const ids = switch (t) {
                    .logical_and_assign => [_]TypeId{ rhs_ty, kept },
                    else => [_]TypeId{ kept, rhs_ty },
                };
                break :blk self.store.unionOf(&ids) catch lhs_ty;
            },

            .logical_and, .logical_or, .nullish_coalesce => self.inferLogical(node),

            .add, .subtract, .multiply, .divide, .modulo, .exponentiate => self.inferArith(node, t),

            .equal, .not_equal, .strict_equal, .strict_not_equal,
            .less_than, .greater_than, .less_equal, .greater_equal,
            .instanceof_expr, .in_expr => blk: {
                const data = self.ast_ref.nodeData(node);
                if (data.lhs == .none or data.rhs == .none) break :blk tymod.ID_ANY;
                break :blk tymod.ID_BOOLEAN;
            },

            .logical_not => blk: {
                const operand = self.ast_ref.nodeData(node).lhs;
                if (operand == .none) break :blk tymod.ID_BOOLEAN;
                const ot = self.typeOf(operand);
                const nt = self.store.get(ot);
                // Fold !<boolean_literal> to the opposite literal.  This keeps
                // chains like `!!promise` working: !promise → false → !false → true.
                if (nt.kind == .boolean_literal) {
                    break :blk self.store.booleanLiteral(!nt.literal_value.boolean) catch tymod.ID_BOOLEAN;
                }
                // type_ref (class/interface/namespace), arrays, objects, functions,
                // non-zero/non-empty literals, and unions of all-truthy members.
                if (self.alwaysTruthyForNot(ot)) {
                    break :blk self.store.booleanLiteral(false) catch tymod.ID_BOOLEAN;
                }
                // null, undefined, void, 0, "" etc., and unions of all-falsy members.
                if (self.alwaysFalsyForNot(ot)) {
                    break :blk self.store.booleanLiteral(true) catch tymod.ID_BOOLEAN;
                }
                break :blk tymod.ID_BOOLEAN;
            },

            .typeof_expr => blk: {
                if (self.ast_ref.nodeData(node).lhs == .none) break :blk tymod.ID_STRING;
                // TypeScript always returns the full typeof-string union for any `typeof expr`,
                // regardless of the operand's static type. Narrowing happens via type guards,
                // not by restricting the type of the typeof expression itself.
                var buf: [8]TypeId = undefined;
                buf[0] = self.store.stringLiteral("bigint") catch tymod.ID_STRING;
                buf[1] = self.store.stringLiteral("boolean") catch tymod.ID_STRING;
                buf[2] = self.store.stringLiteral("function") catch tymod.ID_STRING;
                buf[3] = self.store.stringLiteral("number") catch tymod.ID_STRING;
                buf[4] = self.store.stringLiteral("object") catch tymod.ID_STRING;
                buf[5] = self.store.stringLiteral("string") catch tymod.ID_STRING;
                buf[6] = self.store.stringLiteral("symbol") catch tymod.ID_STRING;
                buf[7] = self.store.stringLiteral("undefined") catch tymod.ID_STRING;
                break :blk self.store.unionOf(&buf) catch tymod.ID_STRING;
            },
            .void_expr => tymod.ID_UNDEFINED,
            .delete_expr => tymod.ID_BOOLEAN,

            // Fold `-<numeric literal>` / `+<numeric literal>` to a number
            // literal so e.g. `-1` matches a `-1` literal type by identity
            // (no-unsafe-enum-comparison's `Fruit | -1; x === -1` overlap check).
            .unary_minus, .unary_plus => blk: {
                const operand = self.ast_ref.nodeData(node).lhs;
                if (operand == .none) break :blk tymod.ID_NUMBER;
                const ot = self.typeOf(operand);
                const lit = self.store.get(ot);
                if (lit.kind == .number_literal) {
                    if (self.ast_ref.nodeTag(node) == .unary_plus) break :blk ot;
                    break :blk self.store.numberLiteral(-lit.literal_value.number) catch tymod.ID_NUMBER;
                }
                if (lit.kind == .bigint_literal) {
                    if (self.ast_ref.nodeTag(node) == .unary_plus) break :blk ot;
                    const pos = lit.literal_value.bigint;
                    const neg = std.fmt.allocPrint(self.gpa, "-{s}", .{pos}) catch break :blk tymod.ID_BIGINT;
                    break :blk self.store.bigintLiteral(neg) catch tymod.ID_BIGINT;
                }
                if (lit.kind == .bigint) break :blk tymod.ID_BIGINT;
                break :blk tymod.ID_NUMBER;
            },

            .bitwise_not,
            .bitwise_and, .bitwise_or, .bitwise_xor,
            .shift_left, .shift_right, .unsigned_shift_right,
            .prefix_inc, .prefix_dec, .postfix_inc, .postfix_dec => tymod.ID_NUMBER,

            .array_literal => self.inferArrayLiteral(node),
            .object_literal => self.inferObjectLiteral(node),

            // Call/new: propagate any through the call (TSe: calling
            // `any` returns `any`).  Default to `unknown` otherwise —
            // we don't infer return types from bodies yet.
            .call_expr, .optional_call_expr, .new_expr => self.inferCallReturn(node),

            .member_expr, .computed_member_expr,
            .optional_member_expr, .optional_computed_member_expr => self.inferMember(node),

            .await_expr => self.inferAwait(node),
            // yield's type is TNext of the enclosing Generator — defaults to any
            // when not explicitly typed.  Using any matches tsc's default behaviour.
            .yield_expr, .yield_delegate => tymod.ID_ANY,

            // Function/arrow expressions build a function_t carrying
            // their signature (param types + return type).  Class
            // expressions still fall back to unknown for now.
            .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                => self.functionTypeFromFnDecl(node),
            .arrow_fn, .async_arrow_fn => self.functionTypeFromArrow(node),
            // Object-literal method shorthands (`{ async f() {} }`).
            // The facade calls typeOf(method_def) when the synthetic FunctionExpression
            // has no _i; this gives returnsThenable the correct function_t.
            .method_def, .computed_method_def => blk: {
                const d = self.ast_ref.nodeData(node);
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(d.rhs));
                const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                const mresult = self.buildFunctionType(
                    md.params_start, md.params_end, md.return_type, md.body, is_async, is_generator,
                );
                if (md.type_params < md.type_params_end)
                    self.registerFnTypeParams(mresult, md.type_params, md.type_params_end);
                break :blk mresult;
            },
            .class_decl => tymod.ID_ANY,
            .class_expr => tymod.ID_UNKNOWN,
            // Spread element `...expr` in call args/array literals:
            // its type is the element type of the spread argument (with
            // literals widened, matching tsc's spread behaviour).
            .spread_element => blk: {
                const se_data = self.ast_ref.nodeData(node);
                if (se_data.lhs == .none) break :blk tymod.ID_ANY;
                const se_ty = self.typeOf(se_data.lhs);
                if (tymod.isAny(&self.store, se_ty)) break :blk tymod.ID_ANY;
                break :blk self.arrayMethodElementTypeOf(se_ty) orelse tymod.ID_ANY;
            },
            else => tymod.ID_ANY,
        };
    }

    /// Decode JS/TS escape sequences in `inner` (raw string content without quotes)
    /// and append the result to `buf`. Returns true on success, false if decoding
    /// was incomplete (caller should fall back to the raw string).
    fn decodeJsEscapes(self: *Checker, inner: []const u8, buf: *std.ArrayList(u8)) bool {
        var i: usize = 0;
        outer: while (i < inner.len) {
            if (inner[i] != '\\' or i + 1 >= inner.len) {
                buf.append(self.gpa, inner[i]) catch { i = inner.len; break :outer; };
                i += 1;
                continue;
            }
            const esc = inner[i + 1];
            switch (esc) {
                'n' => { buf.append(self.gpa, '\n') catch { i = inner.len; break :outer; }; i += 2; },
                'r' => { buf.append(self.gpa, '\r') catch { i = inner.len; break :outer; }; i += 2; },
                't' => { buf.append(self.gpa, '\t') catch { i = inner.len; break :outer; }; i += 2; },
                'b' => { buf.append(self.gpa, 0x08) catch { i = inner.len; break :outer; }; i += 2; },
                'f' => { buf.append(self.gpa, 0x0C) catch { i = inner.len; break :outer; }; i += 2; },
                'v' => { buf.append(self.gpa, 0x0B) catch { i = inner.len; break :outer; }; i += 2; },
                '0'...'7' => {
                    // Octal escape: \N, \NN, or \NNN
                    var val: u32 = esc - '0';
                    var j: usize = i + 2;
                    if (j < inner.len and inner[j] >= '0' and inner[j] <= '7') {
                        val = val * 8 + (inner[j] - '0');
                        j += 1;
                        if (j < inner.len and inner[j] >= '0' and inner[j] <= '7' and val < 32) {
                            val = val * 8 + (inner[j] - '0');
                            j += 1;
                        }
                    }
                    var tbuf: [4]u8 = undefined;
                    const len2 = std.unicode.utf8Encode(@intCast(val), &tbuf) catch {
                        buf.append(self.gpa, '?') catch { i = inner.len; break :outer; };
                        i = j;
                        continue;
                    };
                    buf.appendSlice(self.gpa, tbuf[0..len2]) catch { i = inner.len; break :outer; };
                    i = j;
                },
                'x' => {
                    // \xNN hex escape
                    if (i + 3 < inner.len) {
                        const h1 = std.fmt.charToDigit(inner[i + 2], 16) catch 255;
                        const h2 = std.fmt.charToDigit(inner[i + 3], 16) catch 255;
                        if (h1 <= 15 and h2 <= 15) {
                            buf.append(self.gpa, h1 * 16 + h2) catch { i = inner.len; break :outer; };
                            i += 4;
                            continue;
                        }
                    }
                    buf.appendSlice(self.gpa, "\\x") catch { i = inner.len; break :outer; };
                    i += 2;
                },
                'u' => {
                    // \uNNNN or \u{NNNN}
                    if (i + 2 < inner.len and inner[i + 2] == '{') {
                        const end_brace = std.mem.indexOfScalarPos(u8, inner, i + 3, '}') orelse {
                            buf.appendSlice(self.gpa, "\\u{") catch { i = inner.len; break :outer; };
                            i += 3;
                            continue;
                        };
                        const hex_str = inner[i + 3 .. end_brace];
                        const code_point = std.fmt.parseInt(u21, hex_str, 16) catch {
                            buf.appendSlice(self.gpa, inner[i .. end_brace + 1]) catch { i = inner.len; break :outer; };
                            i = end_brace + 1;
                            continue;
                        };
                        var tbuf: [4]u8 = undefined;
                        const len2 = std.unicode.utf8Encode(code_point, &tbuf) catch {
                            buf.append(self.gpa, '?') catch { i = inner.len; break :outer; };
                            i = end_brace + 1;
                            continue;
                        };
                        buf.appendSlice(self.gpa, tbuf[0..len2]) catch { i = inner.len; break :outer; };
                        i = end_brace + 1;
                    } else if (i + 5 < inner.len) {
                        const hex_str = inner[i + 2 .. i + 6];
                        const code_point = std.fmt.parseInt(u21, hex_str, 16) catch {
                            buf.appendSlice(self.gpa, "\\u") catch { i = inner.len; break :outer; };
                            i += 2;
                            continue;
                        };
                        var tbuf: [4]u8 = undefined;
                        const len2 = std.unicode.utf8Encode(code_point, &tbuf) catch {
                            buf.append(self.gpa, '?') catch { i = inner.len; break :outer; };
                            i += 6;
                            continue;
                        };
                        buf.appendSlice(self.gpa, tbuf[0..len2]) catch { i = inner.len; break :outer; };
                        i += 6;
                    } else {
                        buf.appendSlice(self.gpa, "\\u") catch { i = inner.len; break :outer; };
                        i += 2;
                    }
                },
                else => {
                    buf.append(self.gpa, esc) catch { i = inner.len; break :outer; };
                    i += 2;
                },
            }
        }
        return i >= inner.len;
    }

    fn literalString(self: *Checker, node: NodeIndex) TypeId {
        if (self.stringLiteralIsPropertyKey(node)) return tymod.ID_STRING;
        const tok = self.ast_ref.nodeMainToken(node);
        const raw = self.ast_ref.tokenText(tok);
        if (raw.len < 2) return tymod.ID_STRING;
        const inner = raw[1 .. raw.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
            return self.store.stringLiteral(inner) catch tymod.ID_STRING;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        if (!self.decodeJsEscapes(inner, &buf)) {
            return self.store.stringLiteral(inner) catch tymod.ID_STRING;
        }
        const decoded = self.gpa.dupe(u8, buf.items) catch return self.store.stringLiteral(inner) catch tymod.ID_STRING;
        return self.store.stringLiteral(decoded) catch tymod.ID_STRING;
    }

    fn stringLiteralIsPropertyKey(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return false;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return false;
        if (pidx >= self.ast_ref.nodes.len) return false;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .property) return false;
        if (self.ast_ref.nodeData(parent).lhs != node) return false;
        if (pidx >= parents.len) return false;
        const gp_idx = parents[pidx];
        if (gp_idx == @intFromEnum(NodeIndex.none)) return false;
        if (gp_idx >= self.ast_ref.nodes.len) return false;
        const grandparent: NodeIndex = @enumFromInt(gp_idx);
        return self.ast_ref.nodeTag(grandparent) == .object_literal;
    }

    fn literalNumber(self: *Checker, node: NodeIndex) TypeId {
        const tok = self.ast_ref.nodeMainToken(node);
        const raw = self.ast_ref.tokenText(tok);

        // Remove underscores from the literal
        var cleaned: [256]u8 = undefined;
        var cleaned_idx: usize = 0;
        for (raw) |ch| {
            if (ch != '_') {
                if (cleaned_idx >= cleaned.len) return tymod.ID_NUMBER;
                cleaned[cleaned_idx] = ch;
                cleaned_idx += 1;
            }
        }
        const cleaned_text = cleaned[0..cleaned_idx];

        // Try to parse as hex (0x/0X prefix)
        if (cleaned_text.len >= 2 and cleaned_text[0] == '0' and (cleaned_text[1] == 'x' or cleaned_text[1] == 'X')) {
            if (std.fmt.parseInt(u64, cleaned_text[2..], 16)) |val| {
                return self.store.numberLiteral(@as(f64, @floatFromInt(val))) catch tymod.ID_NUMBER;
            } else |_| {}
        }

        // Try to parse as octal (0o/0O prefix or legacy 0-prefix)
        if (cleaned_text.len >= 2 and cleaned_text[0] == '0') {
            if (cleaned_text[1] == 'o' or cleaned_text[1] == 'O') {
                if (std.fmt.parseInt(u64, cleaned_text[2..], 8)) |val| {
                    return self.store.numberLiteral(@as(f64, @floatFromInt(val))) catch tymod.ID_NUMBER;
                } else |_| {}
            } else if (cleaned_text[1] >= '0' and cleaned_text[1] <= '7') {
                // Legacy octal (0-prefix without 'o')
                if (std.fmt.parseInt(u64, cleaned_text, 8)) |val| {
                    return self.store.numberLiteral(@as(f64, @floatFromInt(val))) catch tymod.ID_NUMBER;
                } else |_| {}
            }
        }

        // Try to parse as binary (0b/0B prefix)
        if (cleaned_text.len >= 2 and cleaned_text[0] == '0' and (cleaned_text[1] == 'b' or cleaned_text[1] == 'B')) {
            if (std.fmt.parseInt(u64, cleaned_text[2..], 2)) |val| {
                return self.store.numberLiteral(@as(f64, @floatFromInt(val))) catch tymod.ID_NUMBER;
            } else |_| {}
        }

        // Fall back to parseFloat for decimal and floating-point
        const v = std.fmt.parseFloat(f64, cleaned_text) catch return tymod.ID_NUMBER;
        return self.store.numberLiteral(v) catch tymod.ID_NUMBER;
    }

    fn literalBigint(self: *Checker, node: NodeIndex) TypeId {
        const tok = self.ast_ref.nodeMainToken(node);
        const raw = self.ast_ref.tokenText(tok);
        // Trim the trailing 'n' suffix.
        if (raw.len < 2 or raw[raw.len - 1] != 'n') return tymod.ID_BIGINT;
        const value = raw[0 .. raw.len - 1];
        return self.store.bigintLiteral(value) catch tymod.ID_BIGINT;
    }

    fn literalBoolean(self: *Checker, node: NodeIndex) TypeId {
        const tok = self.ast_ref.nodeMainToken(node);
        const raw = self.ast_ref.tokenText(tok);
        const v = std.mem.eql(u8, raw, "true");
        return self.store.booleanLiteral(v) catch tymod.ID_BOOLEAN;
    }

    /// Evaluate a template literal to a string literal when all
    /// substitutions are string/number/boolean literals.
    /// Recursively evaluate a numeric literal expression to an f64 value.
    /// Handles number literals, unary +/-, and binary arithmetic on literal operands.
    /// Returns null when the expression is not a numeric constant.
    fn evalLiteralNumericExpr(self: *Checker, node: NodeIndex) ?f64 {
        const tag = self.ast_ref.nodeTag(node);
        const data = self.ast_ref.nodeData(node);
        switch (tag) {
            .number_literal => {
                const tok = self.ast_ref.nodeMainToken(node);
                const text = self.ast_ref.tokenText(tok);
                // Legacy octal literals (0-prefixed, no 'x'/'o'/'b') are only
                // valid in non-strict mode; parse them specially.
                if (text.len >= 2 and text[0] == '0' and
                    text[1] >= '0' and text[1] <= '7')
                {
                    return @floatFromInt(std.fmt.parseInt(u64, text[1..], 8) catch return null);
                }
                return std.fmt.parseFloat(f64, text) catch null;
            },
            .unary_minus => {
                const operand = data.lhs;
                if (operand == .none) return null;
                return if (self.evalLiteralNumericExpr(operand)) |v| -v else null;
            },
            .unary_plus => {
                const operand = data.lhs;
                if (operand == .none) return null;
                return self.evalLiteralNumericExpr(operand);
            },
            .grouping_expr => {
                if (data.lhs == .none) return null;
                return self.evalLiteralNumericExpr(data.lhs);
            },
            .add, .subtract, .multiply, .divide, .modulo, .exponentiate => {
                if (data.lhs == .none or data.rhs == .none) return null;
                const av = self.evalLiteralNumericExpr(data.lhs) orelse return null;
                const bv = self.evalLiteralNumericExpr(data.rhs) orelse return null;
                return switch (tag) {
                    .add => av + bv,
                    .subtract => av - bv,
                    .multiply => av * bv,
                    .divide => if (bv != 0) av / bv else null,
                    .modulo => @rem(av, bv),
                    .exponentiate => std.math.pow(f64, av, bv),
                    else => unreachable,
                };
            },
            .bitwise_and, .bitwise_or, .bitwise_xor,
            .shift_left, .shift_right, .unsigned_shift_right => {
                if (data.lhs == .none or data.rhs == .none) return null;
                const av = self.evalLiteralNumericExpr(data.lhs) orelse return null;
                const bv = self.evalLiteralNumericExpr(data.rhs) orelse return null;
                const ai: i32 = @intFromFloat(av);
                const bi: i32 = @intFromFloat(bv);
                const ri: i32 = switch (tag) {
                    .bitwise_and => ai & bi,
                    .bitwise_or => ai | bi,
                    .bitwise_xor => ai ^ bi,
                    .shift_left => ai << @intCast(@mod(bi, 32)),
                    .shift_right => ai >> @intCast(@mod(bi, 32)),
                    .unsigned_shift_right => @bitCast(@as(u32, @bitCast(ai)) >> @intCast(@mod(bi, 32))),
                    else => unreachable,
                };
                return @floatFromInt(ri);
            },
            .bitwise_not => {
                if (data.lhs == .none) return null;
                const v = self.evalLiteralNumericExpr(data.lhs) orelse return null;
                const i: i32 = @intFromFloat(v);
                return @floatFromInt(~i);
            },
            else => return null,
        }
    }

    /// Otherwise returns ID_STRING (plain string type).
    fn inferTemplateLiteral(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_STRING;

        // Parts alternate template_element (quasi) and expression (interpolation).
        // Accumulate the concatenated string if all substitutions are literals.
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.gpa);

        for (slice) |raw| {
            const part: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(part) == .template_element) {
                // Extract template element text
                const tok = self.ast_ref.nodeMainToken(part);
                const start = self.ast_ref.tokenStart(tok);
                const len = self.ast_ref.tokens.items(.len)[tok];
                const src = self.ast_ref.source;
                if (start + len > src.len) return tymod.ID_STRING;

                var span_start = start;
                var span_end: u32 = start + len;
                if (span_start < span_end and (src[span_start] == '`' or src[span_start] == '}')) span_start += 1;
                if (span_end >= span_start + 2 and src[span_end - 1] == '{' and src[span_end - 2] == '$') {                    span_end -= 2;
                } else if (span_end > span_start and src[span_end - 1] == '`') {
                    span_end -= 1;
                }
                const quasi_text = src[span_start..span_end];
                // Decode escape sequences in template quasi text
                if (std.mem.indexOfScalar(u8, quasi_text, '\\') != null) {
                    if (!self.decodeJsEscapes(quasi_text, &result)) return tymod.ID_STRING;
                } else {
                    result.appendSlice(self.gpa, quasi_text) catch return tymod.ID_STRING;
                }
                continue;
            }

            // Interpolation expression — try to evaluate as a literal.
            // First try direct literal evaluation (handles arithmetic on literals).
            const maybe_num = self.evalLiteralNumericExpr(part);
            const expr_str: []const u8 = if (maybe_num) |num| blk: {
                const formatted = std.fmt.allocPrint(self.gpa, "{}", .{num}) catch return tymod.ID_STRING;
                break :blk formatted;
            } else blk: {
                const expr_ty = self.typeOf(part);
                const t = self.store.get(expr_ty);
                break :blk switch (t.kind) {
                    .string_literal => switch (t.literal_value) { .string => |s| s, else => return tymod.ID_STRING },
                    .number_literal => inner: {
                        const num = switch (t.literal_value) { .number => |n| n, else => return tymod.ID_STRING };
                        break :inner std.fmt.allocPrint(self.gpa, "{}", .{num}) catch return tymod.ID_STRING;
                    },
                    .boolean_literal => switch (t.literal_value) { .boolean => |b| if (b) "true" else "false", else => return tymod.ID_STRING },
                    else => return tymod.ID_STRING,
                };
            };

            result.appendSlice(self.gpa, expr_str) catch return tymod.ID_STRING;
        }

        // Finalize as string literal
        const owned = self.gpa.dupe(u8, result.items) catch return tymod.ID_STRING;
        return self.store.stringLiteral(owned) catch tymod.ID_STRING;
    }

    fn regexpRefType(self: *Checker) TypeId {
        return self.store.typeRef("RegExp", &.{}) catch tymod.ID_ANY;
    }

    /// True when `node` is an object literal with no properties (`{}`).
    fn isEmptyObjectLiteral(self: *Checker, node: NodeIndex) bool {
        if (node == .none) return false;
        if (self.ast_ref.nodeTag(node) != .object_literal) return false;
        const d = self.ast_ref.nodeData(node);
        const slice = self.directRange(d.lhs, d.rhs) orelse return true;
        return slice.len == 0;
    }

    /// True when `node` is the member expression `module.exports`.
    fn isModuleExportsMember(self: *Checker, node: NodeIndex) bool {
        if (node == .none) return false;
        if (self.ast_ref.nodeTag(node) != .member_expr) return false;
        const d = self.ast_ref.nodeData(node);
        if (d.lhs == .none or d.rhs == .none) return false;
        if (self.ast_ref.nodeTag(d.lhs) != .identifier) return false;
        const obj = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(d.lhs));
        if (!std.mem.eql(u8, obj, "module")) return false;
        const prop = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(d.rhs));
        return std.mem.eql(u8, prop, "exports");
    }

    /// Type of a JSX element/fragment expression — `JSX.Element` under a
    /// React-style jsx mode, otherwise `any` (preserve mode / no JSX namespace,
    /// where tsc leaves the element untyped).
    fn jsxElementType(self: *Checker) TypeId {
        if (!self.checker_opts.jsx_react_mode) return tymod.ID_ANY;
        return self.store.typeRef("JSX.Element", &.{}) catch tymod.ID_ANY;
    }

    /// Map a value-side TypeId to the string-literal type(s) that `typeof`
    /// produces at runtime.  Returns a string_literal TypeId, a union of
    /// string_literal TypeIds, or plain `ID_STRING` when the operand type is
    /// too broad to narrow (any / unknown / unresolved).
    fn typeofStringIdOf(self: *Checker, ty: TypeId) TypeId {
        const t = self.store.get(ty);
        return switch (t.kind) {
            .number, .number_literal => self.store.stringLiteral("number") catch tymod.ID_STRING,
            .string, .string_literal => self.store.stringLiteral("string") catch tymod.ID_STRING,
            .boolean, .boolean_literal => self.store.stringLiteral("boolean") catch tymod.ID_STRING,
            .bigint, .bigint_literal => self.store.stringLiteral("bigint") catch tymod.ID_STRING,
            .symbol => self.store.stringLiteral("symbol") catch tymod.ID_STRING,
            .undefined_t, .void_t => self.store.stringLiteral("undefined") catch tymod.ID_STRING,
            .function_t => self.store.stringLiteral("function") catch tymod.ID_STRING,
            // null, object types, arrays, tuples, type refs → "object"
            .null_t, .object_t, .object_keyword, .array_t, .readonly_array_t,
            .tuple_t, .type_ref, .intersection_t => self.store.stringLiteral("object") catch tymod.ID_STRING,
            // Union: recursively compute typeof for each member and deduplicate
            .union_t => blk: {
                var buf: [16]TypeId = undefined;
                var n: usize = 0;
                for (self.store.idsOf(t.list_data)) |m| {
                    const ms = self.typeofStringIdOf(m);
                    var dup = false;
                    for (buf[0..n]) |existing| {
                        if (existing.eq(ms)) { dup = true; break; }
                    }
                    if (!dup) {
                        if (n >= buf.len) break :blk tymod.ID_STRING;
                        buf[n] = ms;
                        n += 1;
                    }
                }
                if (n == 0) break :blk tymod.ID_STRING;
                if (n == 1) break :blk buf[0];
                break :blk self.store.unionOf(buf[0..n]) catch tymod.ID_STRING;
            },
            // any / unknown / never / error / type_param: typeof returns the full union
            else => blk: {
                var buf: [8]TypeId = undefined;
                buf[0] = self.store.stringLiteral("bigint") catch tymod.ID_STRING;
                buf[1] = self.store.stringLiteral("boolean") catch tymod.ID_STRING;
                buf[2] = self.store.stringLiteral("function") catch tymod.ID_STRING;
                buf[3] = self.store.stringLiteral("number") catch tymod.ID_STRING;
                buf[4] = self.store.stringLiteral("object") catch tymod.ID_STRING;
                buf[5] = self.store.stringLiteral("string") catch tymod.ID_STRING;
                buf[6] = self.store.stringLiteral("symbol") catch tymod.ID_STRING;
                buf[7] = self.store.stringLiteral("undefined") catch tymod.ID_STRING;
                break :blk self.store.unionOf(&buf) catch tymod.ID_STRING;
            },
        };
    }

    /// If `node` is the name identifier of a class declaration, return the
    /// TypeId for the class name type.  Non-generic: `C` → typeRef("C").
    /// Generic: `class C<T, U>` → typeRef("C", [typeParam("T"), typeParam("U")])
    /// so it renders as "C<T, U>" matching tsc's annotation on the name.
    /// Returns `typeRef("typeof NS")` when `node` is the name identifier of a
    /// `ts_namespace_decl` or `ts_module_decl` (the fallback path, where semantic
    /// has no reference entry for the declaration name itself).
    fn typeForNamespaceDeclarationName(self: *Checker, node: NodeIndex, name: []const u8) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        if (ptag != .ts_namespace_decl and ptag != .ts_module_decl) return null;
        const data = self.ast_ref.nodeData(parent);
        if (data.lhs != node) return null;
        const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{name}) catch return null;
        return self.store.typeRef(typeof_name, &.{}) catch null;
    }

    fn typeForClassDeclarationName(self: *Checker, node: NodeIndex, name: []const u8) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .class_decl) return null;
        const cdata = self.ast_ref.nodeData(parent);
        if (cdata.lhs == .none) return null;
        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
        if (cd.name != node) return null;
        if (cd.type_params >= cd.type_params_end) {
            return self.store.typeRef(name, &.{}) catch null;
        }
        const n_params = cd.type_params_end - cd.type_params;
        var args_buf: [8]TypeId = undefined;
        const count = @min(n_params, @as(u32, args_buf.len));
        for (0..count) |i| {
            const tp_node: NodeIndex = @enumFromInt(self.ast_ref.extra_data[cd.type_params + @as(u32, @intCast(i))]);
            const tp_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp_node));
            args_buf[i] = self.store.typeParam(tp_name, TypeId.none) catch return null;
        }
        return self.store.typeRef(name, args_buf[0..count]) catch null;
    }

    fn inferIdentifier(self: *Checker, node: NodeIndex) TypeId {
        if (self.symbolForIdentRef(node)) |sym| {
            // Namespace or class identifier in value position → `typeof Name`.
            // Guard: skip type-annotation positions (where tsc says `any`).
            const bkind = self.semantic.symbols.getBindingKind(sym);
            // Namespace star import (`import * as NS`) in value position → `typeof NS`.
            // Exception: node16/nodenext mode requires explicit .js/.mjs/.cjs extensions on
            // relative imports; without one the module is unresolvable and tsc types it `any`.
            if (bkind == .import_binding and !self.identifierInTypePosition(node)) {
                const tok = self.ast_ref.nodeMainToken(node);
                const ns_name = self.ast_ref.tokenText(tok);
                if (self.namespace_import_map.get(ns_name)) |mod_spec| {
                    if (self.checker_opts.isNode16Style() and
                        node16UnresolvableSpec(mod_spec))
                    {
                        return tymod.ID_ANY;
                    }
                    const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{ns_name}) catch return tymod.ID_ANY;
                    return self.store.typeRef(typeof_name, &.{}) catch tymod.ID_ANY;
                }
            }
            if ((bkind == .namespace_decl or bkind == .class_decl or bkind == .enum_decl) and
                !self.identifierInTypePosition(node))
            {
                if (bkind == .namespace_decl or bkind == .enum_decl) {
                    const tok = self.ast_ref.nodeMainToken(node);
                    const ns_name = self.ast_ref.tokenText(tok);
                    if (ns_name.len > 0) {
                        const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{ns_name}) catch return tymod.ID_ANY;
                        return self.store.typeRef(typeof_name, &.{}) catch tymod.ID_ANY;
                    }
                    return tymod.ID_ANY;
                }
                // class_decl: the class NAME in its own declaration has type "C" (not typeof C).
                // A value-position REFERENCE to the class has type "typeof C".
                const parents = self.semantic.parent_indices;
                const nidx = node.toInt();
                if (nidx < parents.len) {
                    const pidx = parents[nidx];
                    if (pidx != @intFromEnum(NodeIndex.none)) {
                        const par_tag = self.ast_ref.nodeTag(@enumFromInt(pidx));
                        if (par_tag == .class_decl or par_tag == .class_expr) {
                            // We're at the class name in the declaration itself — return class type.
                            const base_c2 = self.declaredTypeForSymbol(sym);
                            return self.narrowAtUse(node, sym, base_c2);
                        }
                        // Heritage clause: `extends C<T>` — C is wrapped in ts_instantiation_expr
                        // whose grandparent is the OUTER class_decl.  tsc annotates this as `C<T>`
                        // (the instantiated supertype), not `typeof C`.
                        if (par_tag == .ts_instantiation_expr) {
                            const NONE2: u32 = @intFromEnum(NodeIndex.none);
                            const gp = if (pidx < parents.len) parents[pidx] else NONE2;
                            if (gp != NONE2 and gp < self.ast_ref.nodes.len) {
                                switch (self.ast_ref.nodeTag(@enumFromInt(gp))) {
                                    .class_decl, .class_expr => {
                                        const tok_c = self.ast_ref.nodeMainToken(node);
                                        const cls_name = self.ast_ref.tokenText(tok_c);
                                        if (cls_name.len > 0) {
                                            const inst_d = self.ast_ref.nodeData(@enumFromInt(pidx));
                                            if (inst_d.rhs != .none) {
                                                const ta_sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(inst_d.rhs));
                                                if (ta_sr.start < ta_sr.end and ta_sr.end <= self.ast_ref.extra_data.len) {
                                                    const raw_args = self.ast_ref.extra_data[ta_sr.start..ta_sr.end];
                                                    var arg_buf: [8]TypeId = undefined;
                                                    const argc = @min(raw_args.len, arg_buf.len);
                                                    for (0..argc) |ai| {
                                                        const arg_node: NodeIndex = @enumFromInt(raw_args[ai]);
                                                        // Preserve bare type-parameter names (e.g. `T` in `extends C<T>`):
                                                        // resolveTypeNode would collapse T → its constraint, losing the name.
                                                        const arg_tag = self.ast_ref.nodeTag(arg_node);
                                                        if (arg_tag == .ts_type_reference) {
                                                            const arg_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(arg_node));
                                                            arg_buf[ai] = self.store.typeRef(arg_name, &.{}) catch tymod.ID_ANY;
                                                        } else {
                                                            arg_buf[ai] = self.resolveTypeNode(arg_node);
                                                        }
                                                    }
                                                    return self.store.typeRef(cls_name, arg_buf[0..argc]) catch tymod.ID_ANY;
                                                }
                                            }
                                            // No type args: return bare class type.
                                            return self.store.typeRef(cls_name, &.{}) catch tymod.ID_ANY;
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                }
                // Value reference to the class → typeof C.
                const base_c = self.declaredTypeForSymbol(sym);
                const stored_c = self.store.get(base_c);
                if (stored_c.kind == .type_ref) {
                    const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{stored_c.name}) catch
                        return self.narrowAtUse(node, sym, base_c);
                    return self.store.typeRef(typeof_name, &.{}) catch self.narrowAtUse(node, sym, base_c);
                }
                return self.narrowAtUse(node, sym, base_c);
            }
            // Fundule: function declaration merged with a namespace → value type is
            // `typeof F` (same as if the symbol had bkind == namespace_decl).
            if ((bkind == .function_decl or bkind == .function_decl_annex_b) and
                !self.identifierInTypePosition(node))
            {
                const tok_f = self.ast_ref.nodeMainToken(node);
                const fn_name = self.ast_ref.tokenText(tok_f);
                if (fn_name.len > 0) {
                    if (self.type_decl_nodes.get(fn_name)) |ns_node| {
                        const ns_tag = self.ast_ref.nodeTag(ns_node);
                        if (ns_tag == .ts_namespace_decl or ns_tag == .ts_module_decl) {
                            const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{fn_name}) catch return tymod.ID_ANY;
                            return self.store.typeRef(typeof_name, &.{}) catch tymod.ID_ANY;
                        }
                    }
                    // Expando function: `function foo() {} foo.x = 1` → typeof foo.
                    if (self.expando_fns.contains(fn_name)) {
                        const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{fn_name}) catch return tymod.ID_ANY;
                        return self.store.typeRef(typeof_name, &.{}) catch tymod.ID_ANY;
                    }
                }
            }
            // JS expando object: `var Outer = {}` + `Outer.x = …` → typeof Outer.
            if ((bkind == .@"var" or bkind == .let or bkind == .@"const") and
                !self.identifierInTypePosition(node))
            {
                const tok_v = self.ast_ref.nodeMainToken(node);
                const v_name = self.ast_ref.tokenText(tok_v);
                if (v_name.len > 0 and self.expando_objs.contains(v_name)) {
                    const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{v_name}) catch return tymod.ID_ANY;
                    return self.store.typeRef(typeof_name, &.{}) catch tymod.ID_ANY;
                }
            }
            const base = self.declaredTypeForSymbol(sym);
            // Evolving array (`let x = []`): the binding's declared type is the
            // auto-array (rendered `any`); refine it to the element-union array
            // built from `push`/element-assign contributions.  Only when the
            // declared type is the unrefined `any`/`unknown`/empty-array form,
            // so a real annotation (`let x: number[] = []`) is untouched.
            if (self.checker_opts.no_implicit_any and (bkind == .@"var" or bkind == .let) and
                (base.eq(tymod.ID_ANY) or base.eq(tymod.ID_UNKNOWN) or self.isEmptyArrayType(base)))
            {
                if (self.inferEvolvingArrayType(sym, node)) |arr| {
                    return self.narrowAtUse(node, sym, arr);
                }
            }
            if (!base.eq(tymod.ID_UNKNOWN)) {
                // Annotated const enum vars narrow reads to the initializer's
                // member type (`const c: Choice = Choice.One` → c : Choice.One).
                const flow = self.narrowConstEnumAtUse(sym, node, base) orelse base;
                return self.narrowAtUse(node, sym, flow);
            }
            // Symbol resolves but has no declared type — distinguish between
            // explicit declarations (return any) and implicit globals (try lib).
            const decl_node = self.semantic.symbols.getDeclNode(sym);
            if (decl_node != .none) {
                // Untyped `var`/`let` with no initializer: TypeScript evolves
                // its type from the values assigned to it that reach this use —
                // but only under `noImplicitAny`.  With it off, the binding is
                // a plain `any` everywhere (no evolution).
                if (self.checker_opts.no_implicit_any and (bkind == .@"var" or bkind == .let)) {
                    if (self.inferEvolvingType(sym, node)) |evolved| {
                        return self.narrowAtUse(node, sym, evolved);
                    }
                }
                // Explicitly declared in the file with no type annotation → any
                return tymod.ID_ANY;
            }
            // Implicit global — try the curated lib globals next.
            const tok2 = self.ast_ref.nodeMainToken(node);
            const name2 = self.ast_ref.tokenText(tok2);
            if (self.global_value_types.get(name2)) |t| return t;
            // `ClassName.staticMember` — the class *value* is its static side.
            // Restricted to the object position of a member access so heritage
            // (`extends ClassName`), type, and `new` positions still resolve to
            // the instance type (which shares this same symbol).  decl_node is
            // the class *name* binding; walk up to the enclosing class_decl.
            if (self.identifierIsMemberObject(node)) {
                const class_decl = blk: {
                    const parents = self.semantic.parent_indices;
                    if (decl_node.toInt() < parents.len) {
                        const pidx = parents[decl_node.toInt()];
                        if (pidx != @intFromEnum(NodeIndex.none)) {
                            const p: NodeIndex = @enumFromInt(pidx);
                            if (self.ast_ref.nodeTag(p) == .class_decl) break :blk p;
                        }
                    }
                    break :blk NodeIndex.none;
                };
                if (class_decl != .none) {
                    const cdata = self.ast_ref.nodeData(class_decl);
                    if (cdata.lhs != .none) {
                        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
                        const cname = if (cd.name != .none) self.ast_ref.tokenText(self.ast_ref.nodeMainToken(cd.name)) else "";
                        const st = self.buildClassStaticType(class_decl, cname);
                        if (!st.eq(tymod.ID_UNKNOWN)) return st;
                    }
                }
            }
            return tymod.ID_ANY;
        }
        // Fallback: semantic didn't resolve the reference (common for
        // identifiers used in TS-specific contexts like enum member
        // initializers).  Look up by name through the AST for a
        // declarator with matching name.
        const tok = self.ast_ref.nodeMainToken(node);
        const name = self.ast_ref.tokenText(tok);
        if (name.len == 0) return tymod.ID_UNKNOWN;
        // Annotated identifier with no symbol — e.g. a parameter of a bodyless
        // overload / `declare function` signature.  Its annotation IS its type
        // (declaredTypeAtBinding also applies the `?:` optional-undefined rule).
        {
            const bd = self.ast_ref.nodeData(node);
            if (bd.rhs != .none and self.ast_ref.nodeTag(bd.rhs) == .ts_type_annotation) {
                const ty = self.declaredTypeAtBinding(node);
                if (!ty.eq(tymod.ID_UNKNOWN)) return ty;
            }
        }
        // Rest / defaulted parameter declaration sites (`...args`, `a = 3`)
        // also have no reference-table symbol — resolve via the binding
        // dispatch (rest → any[] / annotation, default → widened literal).
        {
            const parents_arr = self.semantic.parent_indices;
            const nidx2 = node.toInt();
            if (nidx2 < parents_arr.len) {
                const pi2 = parents_arr[nidx2];
                if (pi2 != @intFromEnum(NodeIndex.none)) {
                    const pt2 = self.ast_ref.nodeTag(@enumFromInt(pi2));
                    if (pt2 == .rest_element or pt2 == .assignment_pattern) {
                        const ty = self.declaredTypeAtBinding(node);
                        if (!ty.eq(tymod.ID_UNKNOWN)) return ty;
                    }
                    // Destructured parameter binding (`{ a: x }: T`) at its
                    // declaration site has no reference-table symbol.
                    if (pt2 == .property or pt2 == .shorthand_property or
                        pt2 == .object_pattern or pt2 == .array_pattern)
                    {
                        if (self.destructuredParamBindingType(node)) |ty| {
                            if (!ty.eq(tymod.ID_UNKNOWN)) return ty;
                        }
                        if (self.jsdocParamBindingType(node)) |ty| {
                            if (!ty.eq(tymod.ID_UNKNOWN)) return ty;
                        }
                    }
                    // Simple JS parameter at its declaration site with a JSDoc
                    // `@param` type.
                    switch (pt2) {
                        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                        .arrow_fn, .async_arrow_fn, .ts_declare_function => {
                            if (self.jsdocParamBindingType(node)) |ty| {
                                if (!ty.eq(tymod.ID_UNKNOWN)) return ty;
                            }
                        },
                        else => {},
                    }
                }
            }
        }
        // If this identifier is the key of a ts_property_signature (e.g., `a`
        // in `interface Foo { a: number }`), return its declared type from the
        // annotation rather than falling through to AST search which may find
        // an unrelated variable with the same name.
        if (self.identifierAsPropertySignatureKey(node)) |ty| return ty;
        if (self.identifierAsMethodSignatureKey(node)) |ty| return ty;
        if (self.identifierAsClassPropertyKey(node)) |ty| return ty;
        if (self.identifierAsEnumMemberKey(node)) |ty| return ty;
        // Accessor name or setter parameter: `get x()` / `set x(v)` — these
        // identifiers have no symbol, but declaredTypeAtBinding dispatches on
        // the parent accessor node (getter return type / setter param type,
        // each falling back to the paired accessor).
        accessor_blk: {
            const parents_arr = self.semantic.parent_indices;
            const nidx = node.toInt();
            if (nidx >= parents_arr.len) break :accessor_blk;
            var pidx = parents_arr[nidx];
            if (pidx == @intFromEnum(NodeIndex.none)) break :accessor_blk;
            // Peel a default-value / rest wrapper: `set x(v = 0)`, `set x(...v)`.
            const wrap_tag = self.ast_ref.nodeTag(@enumFromInt(pidx));
            if (wrap_tag == .assignment_pattern or wrap_tag == .rest_element) {
                pidx = parents_arr[pidx];
                if (pidx == @intFromEnum(NodeIndex.none)) break :accessor_blk;
            }
            switch (self.ast_ref.nodeTag(@enumFromInt(pidx))) {
                .getter_def, .setter_def => {
                    const ty = self.declaredTypeAtBinding(node);
                    if (!ty.eq(tymod.ID_UNKNOWN)) return ty;
                },
                else => {},
            }
        }
        // Object-literal property key: `{ x: 0 }` → x has the type of its value (widened).
        // Check before typeOfNameByAstSearch so the property value type takes precedence over
        // an outer variable with the same name.
        if (self.identifierAsObjectLiteralPropertyKey(node)) |ty| return ty;
        // For-in loop binding (declaration node): `for (var a in obj)` or destructuring.
        // Must precede typeOfNameByAstSearch which returns any for uninitialised declarators.
        // Only trigger when the immediate parent is a pattern/declarator/var-decl node
        // (not an expression) — this avoids false positives for unresolved identifiers
        // in the for-in iterable expression (e.g. `foo` in `for (var a in foo.bar)`).
        blk: {
            const parents_arr = self.semantic.parent_indices;
            const nidx = node.toInt();
            if (nidx >= parents_arr.len) break :blk;
            const pidx = parents_arr[nidx];
            if (pidx == @intFromEnum(NodeIndex.none)) break :blk;
            const par_tag = self.ast_ref.nodeTag(@enumFromInt(pidx));
            // Only binding-context parents are acceptable.
            switch (par_tag) {
                .declarator, .array_pattern, .object_pattern, .rest_element,
                .var_decl, .let_decl, .const_decl => {},
                else => break :blk,
            }
            if (self.isForInLoopBinding(node)) return tymod.ID_STRING;
            if (self.forOfBindingElementType(node)) |t| return t;
        }
        if (self.typeOfNameByAstSearch(name)) |t| {
            // Fundule (function + namespace merge): the name maps to both a
            // function in value_decl_by_name AND a namespace in type_decl_nodes.
            // tsc types such an identifier as `typeof F`, not the function type.
            if (self.type_decl_nodes.get(name)) |ns_node| {
                const ns_tag = self.ast_ref.nodeTag(ns_node);
                if (ns_tag == .ts_namespace_decl or ns_tag == .ts_module_decl) {
                    const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{name}) catch return t;
                    return self.store.typeRef(typeof_name, &.{}) catch t;
                }
            }
            // Expando function: `function foo() {} foo.x = 1` → typeof foo.
            if (self.expando_fns.contains(name)) {
                const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{name}) catch return t;
                return self.store.typeRef(typeof_name, &.{}) catch t;
            }
            return t;
        }
        // Class declaration name: `class C { }` or `class C<T>` — return the
        // named type matching tsc's annotation (e.g. `>C : C` / `>C : C<T>`).
        if (self.typeForClassDeclarationName(node, name)) |ty| return ty;
        // Namespace/module declaration name: `namespace NS { }` → `typeof NS`.
        if (self.typeForNamespaceDeclarationName(node, name)) |ty| return ty;
        // When an enum identifier appears, it should be typed as the union of its members
        // (the type-side), not the object type (which is for member access like `Foo.Bar`).
        if (self.enum_kinds.get(name) != null) {
            const typeof_name = std.fmt.allocPrint(self.gpa, "typeof {s}", .{name}) catch return tymod.ID_ANY;
            return self.store.typeRef(typeof_name, &.{}) catch tymod.ID_ANY;
        }
        // Built-in global values (`console`, `Math`, `JSON`, ...) — fall
        // back to the curated lib shapes so member access / calls type
        // correctly without modelling the full lib.d.ts.
        if (self.global_value_types.get(name)) |t| {
            // Several globals appear as named constructor/singleton types in tsc's
            // oracle rather than their structural forms. Return typeRef lazily (not
            // at setup) to avoid seeding the intern map early and exposing latent
            // bugs in substituteTypeId's intern-rehash path.
            const named_form: ?[]const u8 = if (std.mem.eql(u8, name, "Math") or
                std.mem.eql(u8, name, "JSON"))
                name
            else if (std.mem.eql(u8, name, "console"))
                "Console"
            else if (std.mem.eql(u8, name, "Array"))
                "ArrayConstructor"
            else if (std.mem.eql(u8, name, "Object"))
                "ObjectConstructor"
            else if (std.mem.eql(u8, name, "String"))
                "StringConstructor"
            else if (std.mem.eql(u8, name, "Number"))
                "NumberConstructor"
            else if (std.mem.eql(u8, name, "Boolean"))
                "BooleanConstructor"
            else
                null;
            if (named_form) |nf| return self.store.typeRef(nf, &.{}) catch t;
            return t;
        }
        // A known lib.d.ts global we don't model structurally (`Map`, `Reflect`,
        // a TypedArray, …) → Unknown (FP-safe), NOT the error type. A name that
        // is neither in scope nor a known global is genuinely undeclared, which
        // TS types as the *error* type — the type-aware rules flag using it.
        if (isKnownGlobalValue(name)) return tymod.ID_ANY;
        // …unless it's in a type position (`implements FG.A`, `x: Foo`) — a
        // type/namespace reference, not a value, so don't read it as an unsafe
        // value (no-unsafe-member-access excludes heritage member expressions).
        if (self.identifierInTypePosition(node)) return tymod.ID_ANY;
        // TypeScript keywords/reserved words that appear in invalid positions
        // (e.g., `static public;` or used as a variable name) should be typed as
        // `any` not `error`, since they're syntactically present keywords in
        // a bad context.
        if (isKeywordOrReservedWord(name)) return tymod.ID_ANY;
        // `arguments` pseudo-variable: implicitly available in non-arrow functions.
        // Only reached when no explicit symbol or declaration was found for `arguments`.
        if (std.mem.eql(u8, name, "arguments") and self.enclosingNonArrowFunction(node) != .none) {
            return self.store.typeRef("IArguments", &.{}) catch tymod.ID_ANY;
        }
        // Unresolved identifier: return `any` to match TypeScript's permissive
        // behavior for undeclared names. Both `error` and `any` are "gap" in the
        // oracle, but `any` matches when tsc also says `any` (e.g., unresolved imports).
        return tymod.ID_ANY;
    }

    /// Returns the declared type of an identifier that is the key of a
    /// `ts_property_signature` (e.g., `a` in `interface Foo { a: number }`).
    /// Returns null if the identifier is not a property-signature key.
    /// Uses the cached sym_types path to avoid triggering deep type resolution.
    fn identifierAsPropertySignatureKey(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        if (pidx >= self.ast_ref.nodes.len) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .ts_property_signature) return null;
        const pdata = self.ast_ref.nodeData(parent);
        if (pdata.lhs != node) return null;
        if (pdata.rhs == .none or self.ast_ref.nodeTag(pdata.rhs) != .ts_type_annotation) {
            return tymod.ID_ANY;
        }
        const ty_node = self.ast_ref.nodeData(pdata.rhs).lhs;
        // Try the conservative resolver first (cheap, recursion-proof), then
        // fall back to the full resolver for literal types, arrays, named
        // references etc. (`name: '0'`, `children: BigUnion[]`).
        const base_ty = self.resolveSimpleTypeNodeSafe(ty_node) orelse blk: {
            const full = self.resolveTypeNode(ty_node);
            if (full.eq(tymod.ID_UNKNOWN)) return null;
            break :blk full;
        };
        if (self.propertyHasOptionalMarker(node) and !self.typeContainsUndefined(base_ty)) {
            return self.store.unionOf(&.{ base_ty, tymod.ID_UNDEFINED }) catch base_ty;
        }
        return base_ty;
    }

    /// Enum member type for a *declaration* position: the lone member of a
    /// single-member enum is alias-tagged to display `E` in expressions, but
    /// its declaration still renders `E.A` — strip the alias.
    fn enumMemberDeclType(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.enum_name.len > 0 and t.alias_name.len > 0) {
            var copy = t.*;
            copy.alias_name = "";
            return self.store.add(copy) catch id;
        }
        return id;
    }

    /// Merged overload type for `node` when it is the key identifier of a
    /// `ts_method_signature` inside an interface — tsc shows the FULL overload
    /// set at every declaration (`then : { <U>(…): …; <U_1>(…): …; }`).
    fn identifierAsMethodSignatureKey(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .ts_method_signature) return null;
        const pdata = self.ast_ref.nodeData(parent);
        if (pdata.lhs == .none) return null;
        const sig_data = self.ast_ref.extraData(ast.InterfaceSigData, @intFromEnum(pdata.lhs));
        if (sig_data.key != node) return null;
        const method_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(node));
        if (method_name.len == 0) return null;
        // Walk up to the interface declaration.
        var q = parents[pidx];
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var depth: u8 = 0;
        while (q != NONE and depth < 4) : (depth += 1) {
            const qn: NodeIndex = @enumFromInt(q);
            if (self.ast_ref.nodeTag(qn) == .ts_interface_decl) {
                const qdata = self.ast_ref.nodeData(qn);
                if (qdata.lhs == .none) return null;
                const iface = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(qdata.lhs));
                const iface_name = self.ast_ref.tokenText(iface.name);
                const resolved = self.resolveDeclaredType(iface_name) orelse return null;
                const rt = self.store.get(resolved);
                if (rt.kind != .object_t) return null;
                for (self.store.propsOf(rt.object_props)) |p| {
                    if (std.mem.eql(u8, p.name, method_name)) {
                        const pt = self.store.get(p.type_id);
                        if (pt.kind == .function_t) return p.type_id;
                        return null;
                    }
                }
                return null;
            }
            q = parents[q];
        }
        return null;
    }

    /// Return the enum-member type `E.MemberName` when `node` is the key
    /// identifier of a `ts_enum_member` declaration (e.g. `A` in `enum E { A = 1 }`).
    fn identifierAsEnumMemberKey(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .ts_enum_member) return null;
        const pdata = self.ast_ref.nodeData(parent);
        if (pdata.lhs != node) return null; // node is the initializer, not the key
        const member_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(node));
        // Walk up to the enum declaration to get the enum name.
        const gidx = if (parent.toInt() < parents.len) parents[parent.toInt()] else @intFromEnum(NodeIndex.none);
        if (gidx == @intFromEnum(NodeIndex.none)) return null;
        const grandparent: NodeIndex = @enumFromInt(gidx);
        if (self.ast_ref.nodeTag(grandparent) != .ts_enum_decl) return null;
        const gdata = self.ast_ref.nodeData(grandparent);
        if (gdata.lhs == .none) return null;
        const ged = self.ast_ref.extraData(ast.EnumData, @intFromEnum(gdata.lhs));
        const enum_name = self.ast_ref.tokenText(ged.name);
        if (self.buildEnumObjectType(enum_name)) |obj_type| {
            const ot = self.store.get(obj_type);
            if (ot.kind == .object_t) {
                for (self.store.propsOf(ot.object_props)) |p| {
                    if (std.mem.eql(u8, p.name, member_name)) {
                        // Only return if the type is properly enum-tagged (E.Member).
                        // Non-literal members (computed initializers) get untagged types
                        // that would conflict with tsc's E.Member rendering — skip those.
                        const pt = self.store.get(p.type_id);
                        if (pt.enum_name.len > 0) return self.enumMemberDeclType(p.type_id);
                        return null;
                    }
                }
            }
        }
        return null;
    }

    /// Type inference for `property_ident` nodes — the property name on the
    /// right-hand side of a non-computed member expression (`obj.prop`).
    fn inferPropertyIdent(self: *Checker, node: NodeIndex) TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return tymod.ID_ANY;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return tymod.ID_ANY;
        if (pidx >= self.ast_ref.nodes.len) return tymod.ID_ANY;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        const pdata = self.ast_ref.nodeData(parent);
        switch (ptag) {
            .member_expr, .optional_member_expr => {
                if (pdata.rhs != node) return tymod.ID_ANY;
                if (pdata.lhs == .none) return tymod.ID_ANY;
                const obj_ty = self.typeOf(pdata.lhs);
                const tok = self.ast_ref.nodeMainToken(node);
                const prop_name = self.ast_ref.tokenText(tok);
                if (prop_name.len == 0) return tymod.ID_ANY;
                const is_optional = ptag == .optional_member_expr;
                const in_chain = is_optional or self.calleeIsInOptionalChain(pdata.lhs);
                const lookup_ty = if (in_chain) self.stripNullishForLookup(obj_ty) else obj_ty;
                const inner = self.memberOnApparentType(lookup_ty, prop_name, pdata.lhs);
                return self.maybeAddOptionalUndefined(inner, obj_ty, in_chain);
            },
            else => return tymod.ID_ANY,
        }
    }

    /// Returns the declared type of an identifier that is the key of a `property_def`
    /// or `method_def`/`getter_def`/`setter_def` class member.
    fn identifierAsClassPropertyKey(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        const pdata = self.ast_ref.nodeData(parent);
        if (pdata.lhs != node) return null;
        switch (ptag) {
            .property_def => {
                const pd = self.ast_ref.extraData(ast.PropertyData, @intFromEnum(pdata.rhs));
                if (pd.type_annotation != .none and
                    self.ast_ref.nodeTag(pd.type_annotation) == .ts_type_annotation)
                {
                    const ty_node = self.ast_ref.nodeData(pd.type_annotation).lhs;
                    if (self.resolveSimpleTypeNodeSafe(ty_node)) |t| return t;
                    return self.resolveTypeNode(ty_node);
                }
                if (pd.value != .none) {
                    const raw = self.typeOf(pd.value);
                    const t = self.store.get(raw);
                    // Enum members widen to the enum type (`p1 = E.B` → E).
                    if (t.enum_name.len > 0 and self.enumInitIsFresh(pd.value, 0)) {
                        if (self.buildEnumUnionType(t.enum_name)) |eu| return eu;
                    }
                    return switch (t.kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        .bigint_literal => tymod.ID_BIGINT,
                        else => raw,
                    };
                }
                return tymod.ID_ANY;
            },
            .getter_def => {
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(pdata.rhs));
                const fn_ty = self.buildFunctionType(md.params_start, md.params_end, md.return_type, md.body, false, false);
                const ft = self.store.get(fn_ty);
                if (ft.kind == .function_t) {
                    const sigs = self.store.signaturesOf(ft.signatures);
                    if (sigs.len > 0) return sigs[0].return_type;
                }
                return tymod.ID_ANY;
            },
            .method_def, .computed_method_def => {
                // Attempt to build the merged multi-sig type for overloaded methods.
                const ktag = self.ast_ref.nodeTag(pdata.lhs);
                if (ktag == .identifier or ktag == .property_ident) {
                    const mname2 = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pdata.lhs));
                    if (mname2.len > 0) {
                        if (self.classMethodTypeAtDecl(parent, mname2)) |merged2| return merged2;
                    }
                }
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(pdata.rhs));
                const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                const mres = self.buildFunctionType(md.params_start, md.params_end, md.return_type, md.body, is_async, is_generator);
                if (md.type_params < md.type_params_end)
                    self.registerFnTypeParams(mres, md.type_params, md.type_params_end);
                return mres;
            },
            else => return null,
        }
    }

    /// Returns the widened value type of an identifier used as a property key
    /// in an object literal (e.g., `x` in `{ x: 0 }` → number, `y` in `{ y: "hi" }` → string).
    /// Returns null if the identifier is not an object-literal property key.
    /// Distinguished from object-pattern property keys by checking the grandparent node.
    fn identifierAsObjectLiteralPropertyKey(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        if (pidx >= self.ast_ref.nodes.len) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .property) return null;
        const pdata = self.ast_ref.nodeData(parent);
        // The identifier must be the key (lhs), not the value (rhs).
        if (pdata.lhs != node) return null;
        if (pdata.rhs == .none) return null;
        // Distinguish object-literal `{ x: 0 }` (grandparent = object_literal) from
        // object-pattern `{ x: y }` (grandparent = object_pattern). They both use
        // the .property node tag, so we check the grandparent.
        const par_idx = @intFromEnum(parent);
        if (par_idx >= parents.len) return null;
        const gp_pidx = parents[par_idx];
        if (gp_pidx == @intFromEnum(NodeIndex.none)) return null;
        if (gp_pidx >= self.ast_ref.nodes.len) return null;
        if (self.ast_ref.nodeTag(@enumFromInt(gp_pidx)) != .object_literal) return null;
        // Check if the object_literal is wrapped in `as const`. If so, preserve
        // the literal type (TypeScript annotates keys with literal types in as-const context).
        const is_as_const = blk: {
            if (gp_pidx >= parents.len) break :blk false;
            const ggp_pidx = parents[gp_pidx];
            if (ggp_pidx == @intFromEnum(NodeIndex.none)) break :blk false;
            if (ggp_pidx >= self.ast_ref.nodes.len) break :blk false;
            if (self.ast_ref.nodeTag(@enumFromInt(ggp_pidx)) != .ts_as_expr) break :blk false;
            const as_data = self.ast_ref.nodeData(@enumFromInt(ggp_pidx));
            if (as_data.rhs == .none) break :blk false;
            if (self.ast_ref.nodeTag(as_data.rhs) != .ts_type_reference) break :blk false;
            const cname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(as_data.rhs));
            break :blk std.mem.eql(u8, cname, "const");
        };
        const val_ty = self.typeOf(pdata.rhs);
        if (is_as_const) return val_ty;
        // If the value is a type assertion (`0 as 0`, `"a" as "a"`), preserve the
        // asserted literal type — TypeScript does not widen explicitly-asserted types.
        const rhs_tag = self.ast_ref.nodeTag(pdata.rhs);
        if (rhs_tag == .ts_as_expr or rhs_tag == .ts_type_assertion) return val_ty;
        const t = self.store.get(val_ty);
        // Widen primitive literal types to their base types, matching TypeScript's
        // widening behavior for object literal property types.
        return switch (t.kind) {
            .string_literal => tymod.ID_STRING,
            .number_literal => tymod.ID_NUMBER,
            .boolean_literal => tymod.ID_BOOLEAN,
            .bigint_literal => tymod.ID_BIGINT,
            else => val_ty,
        };
    }

    /// Resolve a type annotation node to a TypeId, but only for simple/primitive types.
    /// Returns null for complex types (generics, conditionals) to avoid recursion.
    fn resolveSimpleTypeNodeSafe(self: *Checker, ty_node: NodeIndex) ?TypeId {
        const tag = self.ast_ref.nodeTag(ty_node);
        switch (tag) {
            .ts_type_reference => {
                const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ty_node));
                if (std.mem.eql(u8, name, "number")) return tymod.ID_NUMBER;
                if (std.mem.eql(u8, name, "string")) return tymod.ID_STRING;
                if (std.mem.eql(u8, name, "boolean")) return tymod.ID_BOOLEAN;
                if (std.mem.eql(u8, name, "any")) return tymod.ID_ANY;
                if (std.mem.eql(u8, name, "unknown")) return tymod.ID_UNKNOWN;
                if (std.mem.eql(u8, name, "never")) return tymod.ID_NEVER;
                if (std.mem.eql(u8, name, "void")) return tymod.ID_VOID;
                if (std.mem.eql(u8, name, "null")) return tymod.ID_NULL;
                if (std.mem.eql(u8, name, "undefined")) return tymod.ID_UNDEFINED;
                if (std.mem.eql(u8, name, "symbol")) return tymod.ID_SYMBOL;
                if (std.mem.eql(u8, name, "bigint")) return tymod.ID_BIGINT;
                // Complex named type → don't recurse
                return null;
            },
            .string_literal => return self.literalString(ty_node),
            .number_literal => return self.literalNumber(ty_node),
            .ts_union_type => {
                // Simple unions: only recurse one level.
                const data = self.ast_ref.nodeData(ty_node);
                const slice = self.directRange(data.lhs, data.rhs) orelse return null;
                var buf: [8]TypeId = undefined;
                if (slice.len > buf.len) return null;
                var n: usize = 0;
                for (slice) |raw| {
                    const member = self.resolveSimpleTypeNodeSafe(@enumFromInt(raw)) orelse return null;
                    buf[n] = member;
                    n += 1;
                }
                if (n == 0) return null;
                if (n == 1) return buf[0];
                return self.store.unionOf(buf[0..n]) catch null;
            },
            else => return null,
        }
    }

/// TypeScript keywords and reserved words. Used to distinguish a keyword
    /// used in an invalid position (e.g., `static public;`) from a genuinely
    /// undeclared identifier. Keywords in bad contexts should type as `any`,
    /// not `error`, to match TypeScript's behavior.
    fn isKeywordOrReservedWord(name: []const u8) bool {
        const keywords = [_][]const u8{
            "break",    "case",     "catch",    "class",    "const",    "continue",
            "debugger", "default",  "delete",   "do",       "else",     "export",
            "extends",  "false",    "finally",  "for",      "function", "if",
            "import",   "in",       "instanceof", "let",    "new",      "null",
            "return",   "super",    "switch",   "this",     "throw",    "true",
            "try",      "typeof",   "var",      "void",     "while",    "with",      "yield",
            "static",   "async",    "await",    "interface", "namespace",
            "enum",     "abstract", "as",       "declare",  "from",     "get",
            "of",       "set",      "type",     "module",   "implements", "private",
            "protected", "public",  "readonly", "require",
        };
        inline for (keywords) |kw| {
            if (std.mem.eql(u8, name, kw)) return true;
        }
        return false;
    }

    /// True when `node` is the object (receiver) of a member access —
    /// `node.prop` / `node[expr]` — i.e. `node` is `member.data.lhs`.
    fn identifierIsMemberObject(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        if (node.toInt() >= parents.len) return false;
        const pidx = parents[node.toInt()];
        if (pidx == @intFromEnum(NodeIndex.none)) return false;
        if (pidx >= self.ast_ref.nodes.len) return false;
        const parent: NodeIndex = @enumFromInt(pidx);
        switch (self.ast_ref.nodeTag(parent)) {
            .member_expr, .optional_member_expr,
            .computed_member_expr, .optional_computed_member_expr => {},
            else => return false,
        }
        return self.ast_ref.nodeData(parent).lhs == node;
    }

    /// True when `node` (an identifier) sits in a type position — a qualified
    /// name inside a `ts_type_reference` / `ts_type_query` / type annotation —
    /// rather than a value position.
    fn identifierInTypePosition(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return false;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var p = parents[nidx];
        var guard: u8 = 0;
        while (p != NONE and p < parents.len and p < self.ast_ref.nodes.len and guard < 8) : (guard += 1) {
            switch (self.ast_ref.nodeTag(@enumFromInt(p))) {
                // Parts of a qualified name (`FG.A`) — keep walking up.
                .member_expr, .optional_member_expr, .identifier, .grouping_expr => {},
                .ts_type_reference => {
                    // `typeof X` in type position: the identifier X is looked up
                    // in VALUE space, not type space. Return false so the class/
                    // namespace block produces `typeof X` instead of the instance type.
                    const pp = if (p < parents.len) parents[p] else NONE;
                    if (pp != NONE and pp < self.ast_ref.nodes.len and
                        self.ast_ref.nodeTag(@enumFromInt(pp)) == .ts_typeof_type)
                        return false;
                    return true;
                },
                .ts_type_query, .ts_type_annotation => return true,
                else => return false,
            }
            p = parents[p];
        }
        return false;
    }

    /// ECMAScript global *value* names (lib.es*) that we don't give a structural
    /// shape. Used to tell a real-but-unmodelled global from a genuinely
    /// undeclared identifier so the latter reads as the error type.
    fn isKnownGlobalValue(name: []const u8) bool {
        const names = [_][]const u8{
            "Object",      "Function",   "Array",         "Number",        "Boolean",
            "String",      "Symbol",     "BigInt",        "Math",          "Date",
            "RegExp",      "Error",      "EvalError",     "RangeError",    "ReferenceError",
            "SyntaxError", "TypeError",  "URIError",      "AggregateError", "JSON",
            "Promise",     "Map",        "Set",           "WeakMap",       "WeakSet",
            "WeakRef",     "FinalizationRegistry",        "Proxy",         "Reflect",
            "ArrayBuffer", "SharedArrayBuffer",           "DataView",      "Atomics",
            "Int8Array",   "Uint8Array", "Uint8ClampedArray",              "Int16Array",
            "Uint16Array", "Int32Array", "Uint32Array",   "Float32Array",  "Float64Array",
            "BigInt64Array", "BigUint64Array",            "console",       "globalThis",
            "NaN",         "Infinity",   "undefined",     "parseInt",      "parseFloat",
            "isNaN",       "isFinite",   "decodeURI",     "decodeURIComponent",
            "encodeURI",   "encodeURIComponent",          "eval",          "escape",
            "unescape",    "queueMicrotask",              "structuredClone",
        };
        inline for (names) |g| {
            if (std.mem.eql(u8, name, g)) return true;
        }
        return false;
    }

    /// Check if a member name is a reserved word that would cause issues in strict mode.
    fn isReservedWordForEnum(name: []const u8) bool {
        const reserved = [_][]const u8{
            "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export",
            "extends", "false", "finally", "for", "function", "if",
            "import", "in", "instanceof", "let", "new", "null",
            "return", "super", "switch", "this", "throw", "true",
            "try", "typeof", "var", "void", "while", "with", "yield",
            "static", "async", "await", "interface", "namespace",
            "enum", "abstract", "as", "declare", "from", "get",
            "of", "set", "type", "module", "implements", "private",
            "protected", "public", "readonly", "require",
        };
        inline for (reserved) |r| {
            if (std.mem.eql(u8, name, r)) return true;
        }
        return false;
    }

    /// Build an object_t for an enum's value-side shape — each enum
    /// member becomes a property whose type is the literal value (or
    /// the broad number/string when we can't statically resolve).
    fn buildEnumObjectType(self: *Checker, enum_name: []const u8) ?TypeId {
        const decl = self.type_decl_nodes.get(enum_name) orelse return null;
        if (self.ast_ref.nodeTag(decl) != .ts_enum_decl) return null;
        const data = self.ast_ref.nodeData(decl);
        if (data.lhs == .none) return null;
        const ed = self.ast_ref.extraData(ast.EnumData, @intFromEnum(data.lhs));
        if (ed.members_start >= ed.members_end or ed.members_end > self.ast_ref.extra_data.len) return null;
        var props_list = std.ArrayListUnmanaged(tymod.ObjectProp).empty;
        defer props_list.deinit(self.gpa);
        var auto_idx: f64 = 0;
        for (self.ast_ref.extra_data[ed.members_start..ed.members_end]) |raw| {
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) != .ts_enum_member) continue;
            const md = self.ast_ref.nodeData(m);
            if (md.lhs == .none) continue;
            const member_name_tok = self.ast_ref.nodeMainToken(md.lhs);
            const member_name = self.ast_ref.tokenText(member_name_tok);
            // In strict mode, reserved words as enum member names cause the enum
            // to be treated as any when accessed. Return null to signal the caller
            // to fall back to any.
            if (Checker.isReservedWordForEnum(member_name)) return null;
            const value_ty: TypeId = if (md.rhs != .none) blk: {
                // Initializer specified — use its inferred type.
                const init_ty = self.typeOf(md.rhs);
                // Try to keep numeric auto-increment in sync.
                const tt = self.store.get(init_ty);
                if (tt.kind == .number_literal) auto_idx = tt.literal_value.number + 1;
                break :blk init_ty;
            } else blk: {
                const lit = self.store.numberLiteral(auto_idx) catch tymod.ID_NUMBER;
                auto_idx += 1;
                break :blk lit;
            };
            // Tag string/number-literal members as enum members so the facade
            // surfaces ts.TypeFlags.EnumLiteral + an EnumMember symbol
            // (no-unsafe-enum-comparison). Broad number/string members (no
            // statically-known value) stay untagged.
            const member_ty: TypeId = switch (self.store.get(value_ty).kind) {
                .number_literal, .string_literal => self.store.enumMemberLiteral(value_ty, enum_name, member_name) catch value_ty,
                // Computed initializers (`A = computed(0)`) still produce an
                // opaque member type displaying `E.A` — tsc does not widen
                // computed enum members to number.
                .number, .string => self.store.enumMemberLiteral(value_ty, enum_name, member_name) catch value_ty,
                else => value_ty,
            };
            props_list.append(self.gpa, .{ .name = member_name, .type_id = member_ty }) catch return null;
        }
        if (props_list.items.len == 0) return null;
        // Single-member enum: the member type IS the enum type, and expression
        // positions display the enum name (`E.A : E`).  Alias-tag the lone
        // member; declaration sites strip the alias to render `E.A`.
        if (props_list.items.len == 1) {
            const only_t = self.store.get(props_list.items[0].type_id);
            if (only_t.enum_name.len > 0) {
                var copy = only_t.*;
                copy.alias_name = enum_name;
                props_list.items[0].type_id = self.store.add(copy) catch props_list.items[0].type_id;
            }
        }
        const list = self.store.appendObjectProps(props_list.items) catch return null;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch null;
    }

    /// Number of members declared on an enum, straight from the AST (no type
    /// construction) — used by union rendering to decide whether a union of
    /// members covers the whole enum.
    fn enumDeclMemberCount(self: *Checker, enum_name: []const u8) ?usize {
        const decl = self.type_decl_nodes.get(enum_name) orelse return null;
        if (self.ast_ref.nodeTag(decl) != .ts_enum_decl) return null;
        const data = self.ast_ref.nodeData(decl);
        if (data.lhs == .none) return null;
        const ed = self.ast_ref.extraData(ast.EnumData, @intFromEnum(data.lhs));
        if (ed.members_start > ed.members_end or ed.members_end > self.ast_ref.extra_data.len) return null;
        var count: usize = 0;
        for (self.ast_ref.extra_data[ed.members_start..ed.members_end]) |raw| {
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) == .ts_enum_member) count += 1;
        }
        return count;
    }

    /// Per-member freshness set for enum-member-typed initializers.  tsc
    /// widens a let/var initializer member-wise: FRESH members (from direct
    /// `E.B` accesses, possibly through unannotated const chains) widen to
    /// the full enum type E (which then absorbs sibling members); non-fresh
    /// members (from annotated declarations) stay.  Union dedup makes a
    /// non-fresh copy absorb a fresh one.
    const EnumFreshSet = struct {
        ids: [16]TypeId = undefined,
        fresh: [16]bool = undefined,
        n: usize = 0,
        ename: []const u8 = "",

        fn add(s: *EnumFreshSet, store: *tymod.TypeStore, id: TypeId, is_fresh: bool) bool {
            const t = store.get(id);
            if (t.enum_name.len == 0) return false;
            if (s.ename.len == 0) {
                s.ename = t.enum_name;
            } else if (!std.mem.eql(u8, s.ename, t.enum_name)) return false;
            for (s.ids[0..s.n], 0..) |existing, i| {
                if (existing.eq(id) or std.mem.eql(u8, store.get(existing).name, t.name)) {
                    // Duplicate member: non-fresh wins (union dedup keeps the
                    // regular type).
                    s.fresh[i] = s.fresh[i] and is_fresh;
                    return true;
                }
            }
            if (s.n >= s.ids.len) return false;
            s.ids[s.n] = id;
            s.fresh[s.n] = is_fresh;
            s.n += 1;
            return true;
        }

        /// Add every enum member of `id` (a member or union of members).
        fn addType(s: *EnumFreshSet, store: *tymod.TypeStore, id: TypeId, is_fresh: bool) bool {
            const t = store.get(id);
            if (t.kind == .union_t) {
                for (store.idsOf(t.list_data)) |m| {
                    if (!s.add(store, m, is_fresh)) return false;
                }
                return true;
            }
            return s.add(store, id, is_fresh);
        }
    };

    /// Collect the enum members contributed by an initializer expression with
    /// per-member freshness.  Returns false when the expression isn't a pure
    /// same-enum member composition (caller keeps the unwidened type).
    fn collectEnumFreshMembers(self: *Checker, expr: NodeIndex, depth: u8, set: *EnumFreshSet) bool {
        if (depth > 10 or expr == .none) return false;
        switch (self.ast_ref.nodeTag(expr)) {
            .member_expr, .computed_member_expr => {
                return set.addType(&self.store, self.typeOf(expr), true);
            },
            .grouping_expr => return self.collectEnumFreshMembers(self.ast_ref.nodeData(expr).lhs, depth + 1, set),
            .conditional => {
                const data = self.ast_ref.nodeData(expr);
                if (data.rhs == .none) return false;
                const cd = self.ast_ref.extraData(ast.Conditional, @intFromEnum(data.rhs));
                return self.collectEnumFreshMembers(cd.consequent, depth + 1, set) and
                    self.collectEnumFreshMembers(cd.alternate, depth + 1, set);
            },
            .identifier => {
                const sym = self.symbolForIdentRef(expr) orelse return false;
                const decl = self.semantic.symbols.getDeclNode(sym);
                if (decl == .none) return false;
                const parents = self.semantic.parent_indices;
                var declarator = decl;
                if (self.ast_ref.nodeTag(declarator) != .declarator) {
                    const ni = declarator.toInt();
                    if (ni >= parents.len) return false;
                    const p = parents[ni];
                    if (p == @intFromEnum(NodeIndex.none)) return false;
                    declarator = @enumFromInt(p);
                    if (self.ast_ref.nodeTag(declarator) != .declarator) return false;
                }
                const dd = self.ast_ref.nodeData(declarator);
                if (dd.lhs != .none) {
                    const id_data = self.ast_ref.nodeData(dd.lhs);
                    if (id_data.rhs != .none and self.ast_ref.nodeTag(id_data.rhs) == .ts_type_annotation) {
                        // Annotated declaration → all its members are non-fresh.
                        return set.addType(&self.store, self.typeOf(expr), false);
                    }
                }
                return self.collectEnumFreshMembers(dd.rhs, depth + 1, set);
            },
            else => return false,
        }
    }

    /// Kept for class-field widening: any fresh member in the composition.
    fn enumInitIsFresh(self: *Checker, expr: NodeIndex, depth: u8) bool {
        _ = depth;
        var set = EnumFreshSet{};
        if (!self.collectEnumFreshMembers(expr, 0, &set)) return false;
        for (set.fresh[0..set.n]) |f| {
            if (f) return true;
        }
        return false;
    }

    /// Build the *type-side* of an enum — the union of its member literals (each
    /// enum-tagged), which is what a value annotated `: Fruit` has. Matches tsc:
    /// a single-member enum collapses to that one literal (unionOf), and a
    /// `Fruit | string` wrapping union absorbs string members into `string`.
    /// Backs no-unsafe-enum-comparison when the enum is a declared type rather
    /// than a `Fruit.X` value access.
    fn buildEnumUnionType(self: *Checker, enum_name: []const u8) ?TypeId {
        const obj = self.buildEnumObjectType(enum_name) orelse return null;
        const ot = self.store.get(obj);
        if (ot.kind != .object_t) return null;
        var members_buf: [64]TypeId = undefined;
        var n: usize = 0;
        for (self.store.propsOf(ot.object_props)) |p| {
            if (n >= members_buf.len) break;
            members_buf[n] = p.type_id; // already enum-tagged by buildEnumObjectType
            n += 1;
        }
        if (n == 0) return null;
        const raw = self.store.unionOf(members_buf[0..n]) catch return null;
        // Tag with the enum name so typeToStringInner emits "E" instead of "E.A | E.B | …".
        return self.tagAliasName(raw, enum_name);
    }

    /// Walk the AST looking for a top-level declarator/fn_decl/class_decl
    /// with the given name.  Returns the declared/inferred type, or null
    /// if not found.
    pub fn typeOfNameByAstSearch(self: *Checker, name: []const u8) ?TypeId {
        // Overload handling: when both signature declarations (no body) AND an
        // implementation exist, TS exposes the OVERLOAD SET, not the impl's
        // inferred type — so `function a(): Promise<void>; function a(x): void;
        // function a(x?) {…}` types `a` as `(Promise<void>) | (void)`, not the
        // impl's body-inferred return. Track both; resolve after the scan.
        var fn_decl_fallback: NodeIndex = .none; // first no-body signature
        var fn_impl: NodeIndex = .none; // implementation (with body)
        const list = self.value_decl_by_name.get(name) orelse return null;
        for (list.items) |ni| {
            const t = self.ast_ref.nodeTag(ni);
            switch (t) {
                .declarator => {
                    const data = self.ast_ref.nodeData(ni);
                    if (data.lhs == .none) continue;
                    if (self.ast_ref.nodeTag(data.lhs) != .identifier) continue;
                    const dn = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(data.lhs));
                    if (!std.mem.eql(u8, dn, name)) continue;
                    // Use annotation if present.
                    const ann = self.ast_ref.nodeData(data.lhs).rhs;
                    if (ann != .none and self.ast_ref.nodeTag(ann) == .ts_type_annotation) {
                        return self.resolveTypeNode(self.ast_ref.nodeData(ann).lhs);
                    }
                    if (data.rhs == .none) {
                        // Explicit declaration with no annotation and no initializer
                        // (e.g., `declare var x;` or `var x;` in a function) → any.
                        // This prevents falling through to global_value_types lookups
                        // for explicitly declared names that should resolve to any.
                        return tymod.ID_ANY;
                    }
                    // Declarator with initializer: use the initializer's type, but
                    // if the initializer is unresolvable (unknown/error), return any
                    // since the variable itself is explicitly declared.
                    const init_ty = self.typeOf(data.rhs);
                    if (init_ty.eq(tymod.ID_UNKNOWN) or init_ty.eq(tymod.ID_ERROR)) {
                        return tymod.ID_ANY;
                    }
                    return init_ty;
                },
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .ts_declare_function => {
                    const data = self.ast_ref.nodeData(ni);
                    if (data.lhs == .none) continue;
                    const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
                    if (fd.name == .none) continue;
                    const dn = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(fd.name));
                    if (!std.mem.eql(u8, dn, name)) continue;
                    if (fd.body != .none) {
                        if (fn_impl == .none) fn_impl = ni;
                    } else if (fn_decl_fallback == .none) {
                        fn_decl_fallback = ni;
                    }
                },
                else => {},
            }
        }
        // Overload signatures present → the overload set is the type.
        if (fn_decl_fallback != .none) {
            if (self.functionTypeFromAllOverloads(name)) |t| return t;
            return self.functionTypeFromFnDecl(fn_decl_fallback);
        }
        // No overloads → the implementation's own (most-general) type.
        if (fn_impl != .none) return self.functionTypeFromFnDecl(fn_impl);
        return null;
    }

    /// Walk parent chain looking for `if_stmt` / `logical_and` / `conditional`
    /// constructs whose test narrows `sym`.  Applies the narrowing to
    /// `base` and returns the result.  Handles:
    ///   - `if (x !== null) { ...use... }` → narrowed to non-null.
    ///   - `if (x !== undefined) { ... }` → narrowed to non-undefined.
    ///   - `if (typeof x === 'string') { ... }` → narrowed to string.
    ///   - `if (x === null) { ...use... }` → narrowed to null.
    ///   - Negated forms via `!`.
    fn narrowAtUse(self: *Checker, node: NodeIndex, sym: symbol_mod.SymbolId, base: TypeId) TypeId {
        if (self.semantic.parent_indices.len == 0) return base;
        var ty = base;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var prev = node.toInt();
        var p = self.semantic.parent_indices[prev];
        while (p != NONE) {
            const pn: NodeIndex = @enumFromInt(p);
            const tag = self.ast_ref.nodeTag(pn);
            // Cross-statement narrowing: when we cross into a
            // block_stmt, walk prior siblings looking for
            // `if (cond) <early-exit>;` patterns and apply the
            // inverse-cond narrowing.  Done once at the most-specific
            // block — preceding flow constraints flow inward but not
            // outward across function boundaries.
            if (tag == .block_stmt) {
                ty = self.narrowByPriorEarlyExits(pn, @enumFromInt(prev), sym, ty);
            }
            switch (tag) {
                .if_stmt => {
                    // if_stmt: lhs=cond, rhs=consequent.  If `prev` is
                    // the consequent (or descends from it), apply
                    // narrowing.  TS also narrows the else branch with
                    // the negated condition.
                    const data = self.ast_ref.nodeData(pn);
                    if (@intFromEnum(data.rhs) == prev or self.descendsFrom(node, data.rhs)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, false);
                    }
                },
                .if_else_stmt => {
                    const data = self.ast_ref.nodeData(pn);
                    const ifd = self.ast_ref.extraData(ast.IfData, @intFromEnum(data.rhs));
                    if (self.descendsFrom(node, ifd.consequent)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, false);
                    } else if (self.descendsFrom(node, ifd.alternate)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, true);
                    }
                },
                .conditional => {
                    // `cond ? a : b` — a is narrowed by cond, b by !cond.
                    const data = self.ast_ref.nodeData(pn);
                    const cd = self.ast_ref.extraData(ast.Conditional, @intFromEnum(data.rhs));
                    if (self.descendsFrom(node, cd.consequent)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, false);
                    } else if (self.descendsFrom(node, cd.alternate)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, true);
                    }
                },
                .logical_and => {
                    // `cond && use` — `use` runs only when cond is truthy.
                    const data = self.ast_ref.nodeData(pn);
                    if (self.descendsFrom(node, data.rhs)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, false);
                    }
                },
                .logical_or => {
                    // `cond || use` — `use` runs only when cond is falsy.
                    const data = self.ast_ref.nodeData(pn);
                    if (self.descendsFrom(node, data.rhs)) {
                        ty = self.applyNarrowing(data.lhs, sym, ty, true);
                    }
                },
                else => {},
            }
            prev = p;
            p = self.semantic.parent_indices[p];
        }
        return ty;
    }

    /// Structural equality of two access paths (`foo.a.b` ≡ `foo.a.b`).
    /// Leaf identifiers compare by resolved symbol; intermediate property
    /// names compare by string.  Used for member-access flow narrowing.
    fn accessPathsEqual(self: *Checker, a: NodeIndex, b: NodeIndex) bool {
        var na = a;
        var nb = b;
        while (self.ast_ref.nodeTag(na) == .grouping_expr) na = self.ast_ref.nodeData(na).lhs;
        while (self.ast_ref.nodeTag(nb) == .grouping_expr) nb = self.ast_ref.nodeData(nb).lhs;
        const ta = self.ast_ref.nodeTag(na);
        const tb = self.ast_ref.nodeTag(nb);
        if (ta == .identifier and tb == .identifier) {
            const sa = self.symbolForIdentRef(na) orelse return false;
            const sb = self.symbolForIdentRef(nb) orelse return false;
            return sa.toInt() == sb.toInt();
        }
        if (ta == .this_expr and tb == .this_expr) return true;
        const a_mem = ta == .member_expr or ta == .optional_member_expr;
        const b_mem = tb == .member_expr or tb == .optional_member_expr;
        if (a_mem and b_mem) {
            const da = self.ast_ref.nodeData(na);
            const db = self.ast_ref.nodeData(nb);
            if (da.rhs == .none or db.rhs == .none) return false;
            const pa = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(da.rhs));
            const pb = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(db.rhs));
            if (pa.len == 0 or !std.mem.eql(u8, pa, pb)) return false;
            return self.accessPathsEqual(da.lhs, db.lhs);
        }
        return false;
    }

    /// Flow-narrow a member-access use (`foo.a`) by walking enclosing
    /// guards (`if (foo.a)`, `foo.a && …`, `foo.a !== undefined`) and
    /// matching the guarded path structurally.  Mirrors `narrowAtUse` but
    /// keyed on an access path rather than a single symbol.
    fn narrowMemberAtUse(self: *Checker, node: NodeIndex, base: TypeId) TypeId {
        if (self.semantic.parent_indices.len == 0) return base;
        // Only paths whose type can carry nullish are worth narrowing.
        if (self.store.get(base).kind != .union_t) return base;
        var ty = base;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var prev = node.toInt();
        if (prev >= self.semantic.parent_indices.len) return base;
        var p = self.semantic.parent_indices[prev];
        while (p != NONE) {
            const pn: NodeIndex = @enumFromInt(p);
            const tag = self.ast_ref.nodeTag(pn);
            switch (tag) {
                .if_stmt => {
                    const data = self.ast_ref.nodeData(pn);
                    if (@intFromEnum(data.rhs) == prev or self.descendsFrom(node, data.rhs)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, false);
                    }
                },
                .if_else_stmt => {
                    const data = self.ast_ref.nodeData(pn);
                    const ifd = self.ast_ref.extraData(ast.IfData, @intFromEnum(data.rhs));
                    if (self.descendsFrom(node, ifd.consequent)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, false);
                    } else if (self.descendsFrom(node, ifd.alternate)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, true);
                    }
                },
                .conditional => {
                    const data = self.ast_ref.nodeData(pn);
                    const cd = self.ast_ref.extraData(ast.Conditional, @intFromEnum(data.rhs));
                    if (self.descendsFrom(node, cd.consequent)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, false);
                    } else if (self.descendsFrom(node, cd.alternate)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, true);
                    }
                },
                .logical_and => {
                    const data = self.ast_ref.nodeData(pn);
                    if (self.descendsFrom(node, data.rhs)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, false);
                    }
                },
                .logical_or => {
                    const data = self.ast_ref.nodeData(pn);
                    if (self.descendsFrom(node, data.rhs)) {
                        ty = self.applyMemberNarrowing(data.lhs, node, ty, true);
                    }
                },
                else => {},
            }
            prev = p;
            p = self.semantic.parent_indices[p];
        }
        return ty;
    }

    /// Apply narrowing implied by `test` to the access path `target`.
    fn applyMemberNarrowing(self: *Checker, test_node: NodeIndex, target: NodeIndex, ty: TypeId, negate: bool) TypeId {
        var t = test_node;
        var neg = negate;
        while (self.ast_ref.nodeTag(t) == .logical_not) {
            t = self.ast_ref.nodeData(t).lhs;
            neg = !neg;
        }
        while (self.ast_ref.nodeTag(t) == .grouping_expr) t = self.ast_ref.nodeData(t).lhs;
        const tag = self.ast_ref.nodeTag(t);
        switch (tag) {
            .member_expr, .optional_member_expr => {
                if (self.accessPathsEqual(t, target)) return self.narrowTruthy(ty, neg);
                return ty;
            },
            .logical_and => {
                const data = self.ast_ref.nodeData(t);
                const lty = self.applyMemberNarrowing(data.lhs, target, ty, neg);
                return self.applyMemberNarrowing(data.rhs, target, lty, neg);
            },
            .logical_or => {
                if (neg) {
                    const data = self.ast_ref.nodeData(t);
                    const lty = self.applyMemberNarrowing(data.lhs, target, ty, neg);
                    return self.applyMemberNarrowing(data.rhs, target, lty, neg);
                }
                return ty;
            },
            .strict_not_equal, .not_equal, .strict_equal, .equal => {
                const data = self.ast_ref.nodeData(t);
                var lit_node: NodeIndex = .none;
                if (self.accessPathsEqual(data.lhs, target)) {
                    lit_node = data.rhs;
                } else if (self.accessPathsEqual(data.rhs, target)) {
                    lit_node = data.lhs;
                } else return ty;
                const removed = self.narrowKindFromLiteral(lit_node);
                if (removed != .null_t and removed != .undefined_t) return ty;
                const is_neq = tag == .strict_not_equal or tag == .not_equal;
                // Loose `== null` / `!= null` covers both null and undefined.
                if (tag == .equal or tag == .not_equal) {
                    const remove_nullish = (!is_neq) == neg;
                    return self.narrowNullish(ty, remove_nullish);
                }
                // Strict: remove exactly the tested nullish kind.
                const remove = is_neq != neg;
                return self.narrowUnion(ty, removed, !remove);
            },
            else => return ty,
        }
    }

    /// Within `block`, walk the children that appear *before* `child`
    /// and apply the inverse-condition narrowing from any
    /// `if (cond) <early-exit>;` so subsequent uses of `sym` see the
    /// remaining type.  Early-exit = return / throw / continue / break.
    fn narrowByPriorEarlyExits(
        self: *Checker,
        block: NodeIndex,
        child: NodeIndex,
        sym: symbol_mod.SymbolId,
        base: TypeId,
    ) TypeId {
        const data = self.ast_ref.nodeData(block);
        const slice = self.directRange(data.lhs, data.rhs) orelse return base;
        var ty = base;
        for (slice) |raw| {
            const stmt: NodeIndex = @enumFromInt(raw);
            if (stmt == child) break;
            // Single-armed if with an early exit:
            // `if (cond) return;` / `if (cond) throw ...;`
            const stmt_tag = self.ast_ref.nodeTag(stmt);
            if (stmt_tag == .if_stmt) {
                const sd = self.ast_ref.nodeData(stmt);
                if (statementIsEarlyExit(self, sd.rhs)) {
                    ty = self.applyNarrowing(sd.lhs, sym, ty, true);
                }
            } else if (stmt_tag == .if_else_stmt) {
                // `if (cond) earlyExit() else earlyExit()` — both branches
                // exit, so the post-statement state is unreachable; we
                // can't narrow safely, leave ty unchanged.  Single-branch
                // exit (else branch falls through) is handled by the
                // same shape as if_stmt.
                const sd = self.ast_ref.nodeData(stmt);
                const ifd = self.ast_ref.extraData(ast.IfData, @intFromEnum(sd.rhs));
                if (statementIsEarlyExit(self, ifd.consequent) and !statementIsEarlyExit(self, ifd.alternate)) {
                    ty = self.applyNarrowing(sd.lhs, sym, ty, true);
                } else if (statementIsEarlyExit(self, ifd.alternate) and !statementIsEarlyExit(self, ifd.consequent)) {
                    ty = self.applyNarrowing(sd.lhs, sym, ty, false);
                }
            }
        }
        return ty;
    }

    fn statementIsEarlyExit(self: *Checker, stmt: NodeIndex) bool {
        if (stmt == .none) return false;
        var n = stmt;
        // Peel a single-stmt block: `if (cond) { return; }`.
        if (self.ast_ref.nodeTag(n) == .block_stmt) {
            const d = self.ast_ref.nodeData(n);
            const slice = self.directRange(d.lhs, d.rhs) orelse return false;
            if (slice.len == 0) return false;
            // Only an early exit if every path ends with one — for
            // simplicity, check that the LAST stmt is an early exit
            // (most common in practice).
            n = @enumFromInt(slice[slice.len - 1]);
        }
        return switch (self.ast_ref.nodeTag(n)) {
            .return_stmt, .throw_stmt, .continue_stmt, .break_stmt => true,
            else => false,
        };
    }

    fn descendsFrom(self: *Checker, node: NodeIndex, ancestor: NodeIndex) bool {
        if (ancestor == .none) return false;
        if (node == ancestor) return true;
        if (self.semantic.parent_indices.len == 0) return false;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var p = self.semantic.parent_indices[node.toInt()];
        const target = @intFromEnum(ancestor);
        while (p != NONE) : (p = self.semantic.parent_indices[p]) {
            if (p == target) return true;
        }
        return false;
    }

    /// Apply narrowing implied by `test`.  When `negate` is true, the
    /// narrowing comes from the else branch.
    fn applyNarrowing(self: *Checker, test_node: NodeIndex, sym: symbol_mod.SymbolId, ty: TypeId, negate: bool) TypeId {
        var t = test_node;
        var neg = negate;
        // Peel `!cond`.
        while (self.ast_ref.nodeTag(t) == .logical_not) {
            t = self.ast_ref.nodeData(t).lhs;
            neg = !neg;
        }
        // Peel grouping.
        while (self.ast_ref.nodeTag(t) == .grouping_expr) t = self.ast_ref.nodeData(t).lhs;
        const tag = self.ast_ref.nodeTag(t);
        switch (tag) {
            .strict_not_equal, .not_equal,
            .strict_equal, .equal => {
                return self.narrowEquality(t, sym, ty, neg);
            },
            .instanceof_expr => return self.narrowInstanceof(t, sym, ty, neg),
            // Truthy guard `if (x) {...}` — inside the truthy branch
            // remove null / undefined / 0 / "" / false.  Inside falsy
            // branch keep only those.
            .identifier => {
                if (self.identifierBindsToSym(t, sym)) {
                    return self.narrowTruthy(ty, neg);
                }
                return ty;
            },
            // Logical-and chain: every conjunct narrows the use site
            // (since all must be true for the body to run).
            .logical_and => {
                const data = self.ast_ref.nodeData(t);
                const lty = self.applyNarrowing(data.lhs, sym, ty, neg);
                return self.applyNarrowing(data.rhs, sym, lty, neg);
            },
            // Logical-or: when the condition is in a "negated" (falsy) context,
            // both sides are falsy so we narrow by both.  In truthy context,
            // only the alternative `if (!a || !b)` forms narrow, which we can't
            // easily handle here — leave ty unchanged for the truthy case.
            .logical_or => {
                if (neg) {
                    const data = self.ast_ref.nodeData(t);
                    const lty = self.applyNarrowing(data.lhs, sym, ty, neg);
                    return self.applyNarrowing(data.rhs, sym, lty, neg);
                }
                return ty;
            },
            // Type predicate calls: `isFoo(x)` → narrow x to Foo.
            .call_expr, .optional_call_expr => return self.applyPredicateNarrowing(t, sym, ty, neg),
            else => return ty,
        }
    }

    /// Type predicate narrowing: when `call_node` is `predFn(sym)` and
    /// `predFn` has a `x is T` return signature, narrow `sym` to `T`.
    fn applyPredicateNarrowing(
        self: *Checker,
        call_node: NodeIndex,
        sym: symbol_mod.SymbolId,
        ty: TypeId,
        negate: bool,
    ) TypeId {
        const data = self.ast_ref.nodeData(call_node);
        if (data.lhs == .none) return ty;
        const callee_ty = self.typeOf(data.lhs);
        const ct = self.store.get(callee_ty);
        if (ct.kind != .function_t) return ty;
        const sigs = self.store.signaturesOf(ct.signatures);
        if (sigs.len == 0) return ty;
        const sig = sigs[0];
        if (sig.predicate_param_index == 0xFFFF) return ty;
        if (sig.predicate_target == TypeId.none) return ty;
        // Find the argument at predicate_param_index.
        const args_range = self.safeSubRange(data.rhs) orelse return ty;
        const extra = self.ast_ref.extra_data;
        if (args_range.start > extra.len or args_range.end > extra.len) return ty;
        const args_slice = extra[args_range.start..args_range.end];
        if (sig.predicate_param_index >= args_slice.len) return ty;
        const arg_node: NodeIndex = @enumFromInt(args_slice[sig.predicate_param_index]);
        if (!self.identifierBindsToSym(arg_node, sym)) return ty;
        const target = sig.predicate_target;
        if (negate) return ty;
        // True branch: narrow sym to predicate_target.
        // For any/unknown: just return target directly.
        if (tymod.isAny(&self.store, ty) or tymod.isUnknown(&self.store, ty)) return target;
        // For a union: keep only members assignable to target.
        const tt = self.store.get(ty);
        if (tt.kind == .union_t) {
            var buf: [16]TypeId = undefined;
            var n: usize = 0;
            for (self.store.idsOf(tt.list_data)) |m| {
                if (tymod.isAssignableTo(&self.store, m, target)) {
                    if (n >= buf.len) return target;
                    buf[n] = m;
                    n += 1;
                }
            }
            if (n == 0) return target;
            if (n == 1) return buf[0];
            return self.store.unionOf(buf[0..n]) catch target;
        }
        return target;
    }

    /// `x instanceof Foo` — inside truthy branch, narrow x to Foo.
    fn narrowInstanceof(self: *Checker, cmp: NodeIndex, sym: symbol_mod.SymbolId, ty: TypeId, negate: bool) TypeId {
        const data = self.ast_ref.nodeData(cmp);
        if (!self.identifierBindsToSym(data.lhs, sym)) return ty;
        const rhs = data.rhs;
        if (self.ast_ref.nodeTag(rhs) != .identifier) return ty;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(rhs));
        // Built-in error classes — narrow x to the class instance type.
        // For unknown constructors, leave ty unchanged.
        const class_t = self.store.typeRef(name, &.{}) catch return ty;
        if (negate) {
            // Falsy branch: keep only members NOT assignable to class_t.
            // Approximation: don't narrow.
            return ty;
        }
        // Truthy branch: replace with class_t.
        return class_t;
    }

    /// Truthy guard: remove null / undefined from a union.  Keep
    /// everything else as-is (we don't model literal-falsy types).
    fn narrowTruthy(self: *Checker, ty: TypeId, negate: bool) TypeId {
        const t = self.store.get(ty);
        if (t.kind != .union_t) return ty;
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            const is_falsy_literal = m.eq(tymod.ID_NULL) or
                m.eq(tymod.ID_UNDEFINED) or m.eq(tymod.ID_VOID);
            const keep = if (negate) is_falsy_literal else !is_falsy_literal;
            if (keep) {
                if (n >= buf.len) return ty;
                buf[n] = m;
                n += 1;
            }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch ty;
    }

    /// Narrow against `x === null` / `x !== undefined` / `typeof x === '...'` etc.
    fn narrowEquality(self: *Checker, cmp: NodeIndex, sym: symbol_mod.SymbolId, ty: TypeId, negate: bool) TypeId {
        const data = self.ast_ref.nodeData(cmp);
        const tag = self.ast_ref.nodeTag(cmp);
        const is_neq = tag == .strict_not_equal or tag == .not_equal;
        // typeof narrowing: `typeof x === 'string'` / `typeof x !== 'function'`
        if (self.tryTypeofNarrow(data.lhs, data.rhs, sym, is_neq, negate)) |narrowed| {
            return self.intersectNarrow(ty, narrowed.kind, narrowed.keep_only);
        }
        if (self.tryTypeofNarrow(data.rhs, data.lhs, sym, is_neq, negate)) |narrowed| {
            return self.intersectNarrow(ty, narrowed.kind, narrowed.keep_only);
        }
        // Try `<sym> op <literal>` and `<literal> op <sym>`.
        var sym_side: NodeIndex = .none;
        var lit_side: NodeIndex = .none;
        if (self.identifierBindsToSym(data.lhs, sym)) {
            sym_side = data.lhs;
            lit_side = data.rhs;
        } else if (self.identifierBindsToSym(data.rhs, sym)) {
            sym_side = data.rhs;
            lit_side = data.lhs;
        } else {
            // Try `<sym>.prop op <literal>` — discriminated union narrowing.
            const keep_only_disc = (!is_neq) != negate;
            if (self.isMemberAccessOfSym(data.lhs, sym)) |prop_name| {
                return self.narrowDiscriminantProp(ty, prop_name, data.rhs, keep_only_disc);
            }
            if (self.isMemberAccessOfSym(data.rhs, sym)) |prop_name| {
                return self.narrowDiscriminantProp(ty, prop_name, data.lhs, keep_only_disc);
            }
            return ty;
        }
        _ = &sym_side;
        const removed = self.narrowKindFromLiteral(lit_side);
        if (removed == .none) return ty;
        // Loose equality: `x == null` / `x != null` (and `== undefined`) narrows
        // both null and undefined — TS treats `== null` as `=== null || === undefined`.
        if ((tag == .equal or tag == .not_equal) and
            (removed == .null_t or removed == .undefined_t))
        {
            const remove_nullish = (!is_neq) == negate;
            return self.narrowNullish(ty, remove_nullish);
        }
        const keep_only = (!is_neq) != negate;
        return self.narrowUnion(ty, removed, keep_only);
    }

    const TypeofNarrowSpec = struct { kind: Narrowable, keep_only: bool };

    /// Recognise `typeof <sym-ref> <op> <"kind">`.  Returns the narrow
    /// spec when the typeof's operand resolves to `sym`.
    fn tryTypeofNarrow(self: *Checker, typeof_side: NodeIndex, str_side: NodeIndex, sym: symbol_mod.SymbolId, is_neq: bool, negate: bool) ?TypeofNarrowSpec {
        if (self.ast_ref.nodeTag(typeof_side) != .typeof_expr) return null;
        const operand = self.ast_ref.nodeData(typeof_side).lhs;
        if (!self.identifierBindsToSym(operand, sym)) return null;
        const str_kind = self.typeofStringValue(str_side) orelse return null;
        const keep_only = (!is_neq) != negate;
        return .{ .kind = str_kind, .keep_only = keep_only };
    }

    fn typeofStringValue(self: *Checker, node: NodeIndex) ?Narrowable {
        var n = node;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .string_literal) return null;
        const span = self.ast_ref.nodeSpan(n);
        const src = self.ast_ref.source;
        if (span.end <= span.start + 2 or span.end > src.len) return null;
        const inner = src[span.start + 1 .. span.end - 1];
        if (std.mem.eql(u8, inner, "string")) return .string;
        if (std.mem.eql(u8, inner, "number")) return .number;
        if (std.mem.eql(u8, inner, "boolean")) return .boolean;
        if (std.mem.eql(u8, inner, "bigint")) return .bigint;
        if (std.mem.eql(u8, inner, "undefined")) return .undefined_t;
        if (std.mem.eql(u8, inner, "function")) return .function;
        return null;
    }

    /// Combine narrow spec with current type: for `typeof x === 'string'`
    /// in truthy branch, keep_only=true → keep only string-ish from a
    /// union (or replace primitive `ID_STRING` etc.).  For !==, drop.
    fn intersectNarrow(self: *Checker, ty: TypeId, kind: Narrowable, keep_only: bool) TypeId {
        // Map the narrowable to its primitive TypeId for whole-type
        // replacement when ty isn't a union.
        const target: TypeId = switch (kind) {
            .string => tymod.ID_STRING,
            .number => tymod.ID_NUMBER,
            .boolean => tymod.ID_BOOLEAN,
            .bigint => tymod.ID_BIGINT,
            .undefined_t => tymod.ID_UNDEFINED,
            .null_t => tymod.ID_NULL,
            .void_t => tymod.ID_VOID,
            // `typeof x === 'function'` narrows to the broad `Function` type.
            .function => self.store.typeRef("Function", &.{}) catch return ty,
            .none => return ty,
        };
        const t = self.store.get(ty);
        if (t.kind != .union_t) {
            if (keep_only) {
                // typeof of a non-union value that matches → keep ty;
                // doesn't match → never.
                if (typeIsKindOf(self.store.get(ty).kind, kind)) return ty;
                return target;
            }
            return ty;
        }
        return self.narrowUnion(ty, kind, keep_only);
    }

    const Narrowable = enum(u8) { none, null_t, undefined_t, void_t, string, number, boolean, bigint, function };

    fn narrowKindFromLiteral(self: *Checker, lit: NodeIndex) Narrowable {
        var n = lit;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        const tag = self.ast_ref.nodeTag(n);
        if (tag == .null_literal) return .null_t;
        if (tag == .identifier) {
            const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
            if (std.mem.eql(u8, name, "undefined")) return .undefined_t;
        }
        if (tag == .void_expr) return .undefined_t;
        return .none;
    }

    /// Loose-equality nullish narrowing: `== null` / `== undefined` treats null
    /// and undefined interchangeably.  `remove=true` strips both; `remove=false`
    /// keeps only members that are null or undefined.
    fn narrowNullish(self: *Checker, ty: TypeId, remove: bool) TypeId {
        const t = self.store.get(ty);
        if (t.kind != .union_t) {
            const is_nullish = self.idMatchesNarrowable(ty, .null_t) or
                self.idMatchesNarrowable(ty, .undefined_t);
            if (remove) return if (is_nullish) tymod.ID_NEVER else ty;
            return if (is_nullish) ty else tymod.ID_NEVER;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            const is_nullish = self.idMatchesNarrowable(m, .null_t) or
                self.idMatchesNarrowable(m, .undefined_t);
            const keep = if (remove) !is_nullish else is_nullish;
            if (keep) {
                if (n >= buf.len) return ty;
                buf[n] = m;
                n += 1;
            }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch ty;
    }

    /// Remove a kind from a union, or keep only that kind.
    fn narrowUnion(self: *Checker, ty: TypeId, kind: Narrowable, keep_only: bool) TypeId {
        const t = self.store.get(ty);
        if (t.kind != .union_t) {
            const matches = self.idMatchesNarrowable(ty, kind);
            if (keep_only) return if (matches) ty else tymod.ID_NEVER;
            return if (matches) tymod.ID_NEVER else ty;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            const matches = self.idMatchesNarrowable(m, kind);
            if ((keep_only and matches) or (!keep_only and !matches)) {
                if (n >= buf.len) return ty;
                buf[n] = m;
                n += 1;
            }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch ty;
    }

    fn idMatchesNarrowable(self: *Checker, id: TypeId, kind: Narrowable) bool {
        // Also accept the corresponding literal kind for typeof
        // checks (e.g. `typeof x === 'string'` matches both `string`
        // and `'foo'` (string_literal)).
        const k = self.store.get(id).kind;
        if (typeIsKindOf(k, kind)) return true;
        return switch (kind) {
            .null_t => id.eq(tymod.ID_NULL),
            .undefined_t => id.eq(tymod.ID_UNDEFINED) or k == .void_t,
            .void_t => id.eq(tymod.ID_VOID),
            .string => id.eq(tymod.ID_STRING),
            .number => id.eq(tymod.ID_NUMBER),
            .boolean => id.eq(tymod.ID_BOOLEAN),
            .bigint => id.eq(tymod.ID_BIGINT),
            .function => k == .function_t,
            .none => false,
        };
    }

    fn typeIsKindOf(k: tymod.TypeKind, n: Narrowable) bool {
        return switch (n) {
            .string => k == .string or k == .string_literal,
            .number => k == .number or k == .number_literal,
            .boolean => k == .boolean or k == .boolean_literal,
            .bigint => k == .bigint or k == .bigint_literal,
            .undefined_t => k == .undefined_t or k == .void_t,
            .null_t => k == .null_t,
            .void_t => k == .void_t,
            .function => k == .function_t,
            .none => false,
        };
    }

    fn identifierBindsToSym(self: *Checker, node: NodeIndex, sym: symbol_mod.SymbolId) bool {
        if (self.ast_ref.nodeTag(node) != .identifier) return false;
        const s = self.symbolForIdentRef(node) orelse return false;
        return s.toInt() == sym.toInt();
    }

    /// Check if `node` is `<sym>.propName` (member_expr with sym as object).
    /// Returns the property name string when it matches.
    fn isMemberAccessOfSym(self: *Checker, node: NodeIndex, sym: symbol_mod.SymbolId) ?[]const u8 {
        const tag = self.ast_ref.nodeTag(node);
        if (tag != .member_expr and tag != .optional_member_expr) return null;
        const data = self.ast_ref.nodeData(node);
        if (!self.identifierBindsToSym(data.lhs, sym)) return null;
        if (data.rhs == .none) return null;
        const prop_tok = self.ast_ref.nodeMainToken(data.rhs);
        const name = self.ast_ref.tokenText(prop_tok);
        return if (name.len > 0) name else null;
    }

    /// Create a TypeId from a literal AST node for discriminant comparison.
    fn literalNodeToTypeId(self: *Checker, node: NodeIndex) ?TypeId {
        var n = node;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        return switch (self.ast_ref.nodeTag(n)) {
            .string_literal => self.literalString(n),
            .number_literal => self.literalNumber(n),
            .boolean_literal => self.literalBoolean(n),
            .null_literal => tymod.ID_NULL,
            .identifier => blk: {
                const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
                if (std.mem.eql(u8, name, "undefined")) break :blk tymod.ID_UNDEFINED;
                break :blk null;
            },
            else => null,
        };
    }

    /// Look up `prop_name` directly on a single non-union type.
    fn directPropOf(self: *Checker, ty: TypeId, prop_name: []const u8) TypeId {
        const t = self.store.get(ty);
        switch (t.kind) {
            .object_t => {
                for (self.store.propsOf(t.object_props)) |p| {
                    if (std.mem.eql(u8, p.name, prop_name)) return p.type_id;
                }
                return tymod.ID_UNKNOWN;
            },
            .type_ref => {
                if (self.resolveDeclaredType(t.name)) |resolved| {
                    if (!resolved.eq(ty)) return self.directPropOf(resolved, prop_name);
                }
                return tymod.ID_UNKNOWN;
            },
            .intersection_t => {
                for (self.store.idsOf(t.list_data)) |m| {
                    const r = self.directPropOf(m, prop_name);
                    if (!r.eq(tymod.ID_UNKNOWN)) return r;
                }
                return tymod.ID_UNKNOWN;
            },
            else => return tymod.ID_UNKNOWN,
        }
    }

    /// Narrow a union type by testing `sym.propName === litNode`.
    /// Keeps only members whose `propName` property is assignable to the literal type.
    fn narrowDiscriminantProp(
        self: *Checker,
        ty: TypeId,
        prop_name: []const u8,
        lit_node: NodeIndex,
        keep_only: bool,
    ) TypeId {
        const lit_id = self.literalNodeToTypeId(lit_node) orelse return ty;
        const t = self.store.get(ty);
        if (t.kind != .union_t) {
            const prop_ty = self.directPropOf(ty, prop_name);
            if (prop_ty.eq(tymod.ID_UNKNOWN)) return ty;
            const matches = tymod.isAssignableTo(&self.store, prop_ty, lit_id);
            return if (keep_only == matches) ty else tymod.ID_NEVER;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            const prop_ty = self.directPropOf(m, prop_name);
            const matches = if (prop_ty.eq(tymod.ID_UNKNOWN))
                true // unknown prop: can't narrow, keep member
            else
                tymod.isAssignableTo(&self.store, prop_ty, lit_id);
            if (keep_only == matches) {
                if (n >= buf.len) return ty;
                buf[n] = m;
                n += 1;
            }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch ty;
    }

    /// Find the symbol bound to an identifier reference, if any.
    fn symbolForIdentRef(self: *Checker, ident_node: NodeIndex) ?symbol_mod.SymbolId {
        const ni = ident_node.toInt();
        if (ni >= self.node_to_sym.len) return null;
        const v = self.node_to_sym[ni];
        if (v == 0xFFFFFFFF) return null;
        return symbol_mod.SymbolId.fromInt(v);
    }

    /// Build, once: node → CFG segment id, and the reverse index from a
    /// symbol to the `x = expr` writes targeting it.  The resolver leaves
    /// write_expr_id `.none`, so the assigned expression is recovered from the
    /// AST (a write reference's node is the `=` target; its parent `assign`
    /// node's rhs is the value).  Each write's effect position is the END of
    /// the RHS so a write does not kill reads inside its own RHS.
    fn buildEvolvingIndex(self: *Checker) void {
        self.evolving_index_built = true;
        const refs = &self.semantic.references;
        const total = refs.count();
        if (total == 0) return;
        const node_count = self.node_types.len;
        self.node_seg = self.gpa.alloc(u32, node_count) catch &.{};
        if (self.node_seg.len == node_count) @memset(self.node_seg, NONE_SEG);
        const parents = self.semantic.parent_indices;
        const seg_col = refs.list.items(.seg_id);
        const node_col = refs.list.items(.node_id);
        const kind_col = refs.list.items(.kind);
        const sym_col = refs.list.items(.symbol_id);
        var ri: usize = 0;
        while (ri < total) : (ri += 1) {
            const ni = @intFromEnum(node_col[ri]);
            if (ni < self.node_seg.len) self.node_seg[ni] = seg_col[ri];
            if (@intFromEnum(sym_col[ri]) == @intFromEnum(symbol_mod.SymbolId.none)) continue;
            // Index both plain `=` (`.write`) and compound `+=`/`<<=`/…
            // (`.read_write`).  They are used asymmetrically downstream: a
            // READ reference sees only plain writes (tsc keeps the prior
            // narrowed type across a compound op), while a WRITE-TARGET
            // reference also sees compound writes (its reported type reflects
            // the value the compound op just produced).
            if (kind_col[ri] != .write and kind_col[ri] != .read_write) continue;
            if (ni >= parents.len) continue;
            const pidx = parents[ni];
            if (pidx == @intFromEnum(NodeIndex.none)) continue;
            const parent: NodeIndex = @enumFromInt(pidx);
            const ptag = self.ast_ref.nodeTag(parent);
            if (!isAssignTag(ptag)) continue;
            const pd = self.ast_ref.nodeData(parent);
            if (@intFromEnum(pd.lhs) != ni or pd.rhs == .none) continue;
            const symid = sym_col[ri].toInt();
            const gop = self.evolving_assign_index.getOrPut(self.gpa, symid) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(self.gpa, .{
                .rhs = pd.rhs,
                .assign = parent,
                .op = ptag,
                .seg = seg_col[ri],
                .pos = self.ast_ref.nodeSpan(@as(NodeIndex, @enumFromInt(ni))).start,
            }) catch {};
        }

        // ── Evolving arrays ──────────────────────────────────────────────
        // Pass A: a var/let assigned an empty array literal `[]` is an
        // evolving (auto-)array.
        ri = 0;
        while (ri < total) : (ri += 1) {
            const sid = sym_col[ri];
            if (@intFromEnum(sid) == @intFromEnum(symbol_mod.SymbolId.none)) continue;
            const bkind = self.semantic.symbols.getBindingKind(sid);
            if (bkind != .@"var" and bkind != .let) continue;
            const node: NodeIndex = node_col[ri];
            const valn = self.assignedValueOf(node) orelse continue;
            // A *non-empty* array-literal write (`x = [5, "hello"]`, `x = [true]`)
            // makes the binding a fixed (non-evolving) array; disqualify it even
            // if `x = []` also appears (TS's evolving inference fails → `any`).
            if (self.ast_ref.nodeTag(valn) == .array_literal and !self.isEmptyArrayLiteral(valn)) {
                _ = self.evolving_array_syms.remove(sid.toInt());
                self.evolving_array_disq.put(self.gpa, sid.toInt(), {}) catch {};
                continue;
            }
            if (!self.isEmptyArrayLiteral(valn)) continue;
            if (self.evolving_array_disq.contains(sid.toInt())) continue;
            // A binding whose *initializer* is something other than `[]` has a
            // declared type from it (`let foo = map.get(k)` is `T[] | undefined`)
            // and is not an evolving array, even if `foo = []` appears later.
            const decl_init = self.bindingDeclInit(sid);
            if (decl_init != .none and !self.isEmptyArrayLiteral(decl_init)) continue;
            self.evolving_array_syms.put(self.gpa, sid.toInt(), {}) catch {};
            const symid2 = sid.toInt();
            if (decl_init != .none) {
                // Initializer is `[]` → auto-array from the declaration onward.
                self.evolving_array_init.put(self.gpa, symid2, {}) catch {};
            } else {
                // `x = []` reset write — records where the auto-array begins.
                const rgop = self.evolving_array_resets.getOrPut(self.gpa, symid2) catch continue;
                if (!rgop.found_existing) rgop.value_ptr.* = .empty;
                rgop.value_ptr.append(self.gpa, .{
                    .rhs = valn,
                    .assign = .none,
                    .op = .assign,
                    .seg = seg_col[ri],
                    .pos = self.ast_ref.nodeSpan(node).start,
                }) catch {};
            }
        }
        // Pass B: collect element contributions (`x.push(v)`, `x[i] = v`).
        if (self.evolving_array_syms.count() != 0) {
            ri = 0;
            while (ri < total) : (ri += 1) {
                const sid = sym_col[ri];
                if (@intFromEnum(sid) == @intFromEnum(symbol_mod.SymbolId.none)) continue;
                if (!self.evolving_array_syms.contains(sid.toInt())) continue;
                self.collectArrayContribs(sid.toInt(), node_col[ri], seg_col[ri]);
            }
        }
    }

    /// True for `never[]` / `any[]` — the unrefined empty-array element forms.
    fn isEmptyArrayType(self: *Checker, ty: TypeId) bool {
        const t = self.store.get(ty);
        if (t.kind != .array_t and t.kind != .readonly_array_t) return false;
        const elems = self.store.idsOf(t.list_data);
        if (elems.len != 1) return false;
        return elems[0].eq(tymod.ID_NEVER) or elems[0].eq(tymod.ID_ANY);
    }

    /// The initializer node of a var/let binding's declarator, or `.none`.
    fn bindingDeclInit(self: *Checker, sym: symbol_mod.SymbolId) NodeIndex {
        const decl = self.semantic.symbols.getDeclNode(sym);
        if (decl == .none) return .none;
        var n = decl;
        if (self.ast_ref.nodeTag(n) != .declarator) {
            const ni = n.toInt();
            if (ni >= self.semantic.parent_indices.len) return .none;
            const p = self.semantic.parent_indices[ni];
            if (p == @intFromEnum(NodeIndex.none)) return .none;
            n = @enumFromInt(p);
            if (self.ast_ref.nodeTag(n) != .declarator) return .none;
        }
        return self.ast_ref.nodeData(n).rhs;
    }

    /// Peel grouping and report whether `node` is an empty array literal `[]`.
    fn isEmptyArrayLiteral(self: *Checker, node: NodeIndex) bool {
        var n = node;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .array_literal) return false;
        const d = self.ast_ref.nodeData(n);
        const r = self.directRange(d.lhs, d.rhs);
        return r == null or r.?.len == 0;
    }

    /// The value assigned to `node` when it is an `=` target or a declarator
    /// binding identifier, else null.
    fn assignedValueOf(self: *Checker, node: NodeIndex) ?NodeIndex {
        const ni = node.toInt();
        if (ni >= self.semantic.parent_indices.len) return null;
        const pidx = self.semantic.parent_indices[ni];
        if (pidx == @intFromEnum(NodeIndex.none)) return null;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        if (ptag != .assign and ptag != .declarator) return null;
        const pd = self.ast_ref.nodeData(parent);
        if (@intFromEnum(pd.lhs) != ni or pd.rhs == .none) return null;
        return pd.rhs;
    }

    fn addArrayContrib(self: *Checker, symid: u32, value: NodeIndex, seg: u32, pos: u32) void {
        const gop = self.evolving_array_contribs.getOrPut(self.gpa, symid) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(self.gpa, .{ .rhs = value, .assign = NodeIndex.none, .op = .assign, .seg = seg, .pos = pos }) catch {};
    }

    /// When `xnode` (a reference to an evolving-array symbol) is the receiver of
    /// `x.push(...)`/`x.unshift(...)` or the object of `x[i] = v`, record the
    /// contributed element value(s).
    fn collectArrayContribs(self: *Checker, symid: u32, xnode: NodeIndex, seg: u32) void {
        const parents = self.semantic.parent_indices;
        const ni = xnode.toInt();
        if (ni >= parents.len) return;
        const pidx = parents[ni];
        if (pidx == @intFromEnum(NodeIndex.none)) return;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        const md = self.ast_ref.nodeData(parent);
        if (@intFromEnum(md.lhs) != ni) return; // x must be the object/receiver
        if (ptag == .member_expr) {
            if (md.rhs == .none) return;
            const method = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
            if (!std.mem.eql(u8, method, "push") and !std.mem.eql(u8, method, "unshift")) return;
            const pi = parent.toInt();
            if (pi >= parents.len) return;
            const gpi = parents[pi];
            if (gpi == @intFromEnum(NodeIndex.none)) return;
            const gp: NodeIndex = @enumFromInt(gpi);
            if (self.ast_ref.nodeTag(gp) != .call_expr) return;
            const cd = self.ast_ref.nodeData(gp);
            if (@intFromEnum(cd.lhs) != pi) return; // member is the callee
            const args = self.safeSubRange(cd.rhs) orelse return;
            const extra = self.ast_ref.extra_data;
            if (args.start > extra.len or args.end > extra.len) return;
            const cpos = self.ast_ref.nodeSpan(gp).start;
            var k = args.start;
            while (k < args.end) : (k += 1) {
                self.addArrayContrib(symid, @enumFromInt(extra[k]), seg, cpos);
            }
        } else if (ptag == .computed_member_expr) {
            const pi = parent.toInt();
            if (pi >= parents.len) return;
            const gpi = parents[pi];
            if (gpi == @intFromEnum(NodeIndex.none)) return;
            const gp: NodeIndex = @enumFromInt(gpi);
            if (self.ast_ref.nodeTag(gp) != .assign) return;
            const ad = self.ast_ref.nodeData(gp);
            if (@intFromEnum(ad.lhs) != pi or ad.rhs == .none) return;
            self.addArrayContrib(symid, ad.rhs, seg, self.ast_ref.nodeSpan(gp).start);
        }
    }

    /// True when `node` is `ancestor` or lies within its subtree (walking up
    /// parent links).  Used to tell whether a read lies inside a write's own
    /// assignment (so that write doesn't reach it).
    fn nodeWithin(self: *Checker, node: NodeIndex, ancestor: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        var cur = node.toInt();
        const target = ancestor.toInt();
        var guard: u32 = 0;
        while (guard < 4096) : (guard += 1) {
            if (cur == target) return true;
            if (cur >= parents.len) return false;
            const p = parents[cur];
            if (p == @intFromEnum(NodeIndex.none)) return false;
            cur = p;
        }
        return false;
    }

    /// Index (into `writes`) of the nearest *plain* `=` write in segment `seg`
    /// that reaches the read `use_node` (at `bound`): position before the read
    /// and not the assignment the read itself belongs to.  Compound writes
    /// (`+=` …) are skipped — tsc keeps the prior narrowed type across them.
    fn bestWriteInSeg(self: *Checker, writes: []const EvolvingWrite, seg: u32, bound: u32, use_node: NodeIndex) ?usize {
        var best: ?usize = null;
        var best_pos: u32 = 0;
        for (writes, 0..) |w, i| {
            if (w.seg != seg or w.pos >= bound or w.op != .assign) continue;
            if (self.nodeWithin(use_node, w.assign)) continue; // read is in this write's RHS
            if (best == null or w.pos > best_pos) {
                best = i;
                best_pos = w.pos;
            }
        }
        return best;
    }

    /// Push every not-yet-visited predecessor of `seg` (normal + looped) onto
    /// the worklist.  Returns true when `seg` has NO predecessors — a CFG
    /// entry, i.e. the walk reached the code-path start along this path.
    fn pushPrevSegs(self: *Checker, cpr: anytype, seg: u32) bool {
        if (seg >= cpr.seg_count) return false;
        var has_prev = false;
        inline for (.{
            .{ cpr.seg_all_prev_start, cpr.seg_all_prev_end, cpr.all_prev_targets },
            .{ cpr.seg_looped_prev_start, cpr.seg_looped_prev_end, cpr.looped_targets },
        }) |edge| {
            var k = edge[0][seg];
            const end = edge[1][seg];
            const pool = edge[2];
            while (k < end) : (k += 1) {
                has_prev = true;
                const prev = pool[k];
                const gop = self.seg_reach_set.getOrPut(self.gpa, prev) catch continue;
                if (!gop.found_existing) self.seg_worklist.append(self.gpa, prev) catch {};
            }
        }
        return !has_prev;
    }

    /// Kill-aware reaching definitions: marks `reaches[i]` for each write that
    /// reaches the use along some path with no intervening write (a segment
    /// carrying a write is a sink).  Returns true when a *write-free* path
    /// reaches the use — the binding is still its un-narrowed auto (`any`)
    /// type there, so tsc reports `any` and we must not evolve it.
    fn computeReachingWrites(
        self: *Checker,
        cpr: anytype,
        writes: []const EvolvingWrite,
        reaches: []bool,
        use_seg: u32,
        use_pos: u32,
        use_node: NodeIndex,
    ) bool {
        self.seg_reach_set.clearRetainingCapacity();
        self.seg_worklist.clearRetainingCapacity();
        if (self.bestWriteInSeg(writes, use_seg, use_pos, use_node)) |bi| {
            reaches[bi] = true;
            return false;
        }
        self.seg_reach_set.put(self.gpa, use_seg, {}) catch return true;
        var unwritten = self.pushPrevSegs(cpr, use_seg);
        while (self.seg_worklist.pop()) |seg| {
            if (seg >= cpr.seg_count) continue;
            if (self.bestWriteInSeg(writes, seg, std.math.maxInt(u32), use_node)) |bi| {
                reaches[bi] = true; // reaching def on this path; do not expand
                continue;
            }
            if (self.pushPrevSegs(cpr, seg)) unwritten = true;
        }
        return unwritten;
    }

    /// Evolving-any: type a use of an untyped `var`/`let` as the union of the
    /// assigned values that reach it.  Returns null (→ caller yields `any`)
    /// when a write-free path reaches the use, when no write reaches it, or
    /// when a reaching write is itself `any`/`unknown`.
    fn isAssignTag(tag: ast.Node.Tag) bool {
        return switch (tag) {
            .assign,
            .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign,
            .exp_assign, .and_assign, .or_assign, .xor_assign, .shl_assign,
            .shr_assign, .ushr_assign, .logical_and_assign, .logical_or_assign,
            .nullish_assign => true,
            else => false,
        };
    }

    /// True when `node` is the target of a *plain* `=` assignment (a pure
    /// write).  TypeScript reports the binding's declared (evolved) type at
    /// such a target, not the flow type — whereas a compound-assignment target
    /// (`node += …`) is a read-modify-write and gets the flow type like a read.
    fn isPlainAssignTarget(self: *Checker, node: NodeIndex) bool {
        const ni = node.toInt();
        if (ni >= self.semantic.parent_indices.len) return false;
        const pidx = self.semantic.parent_indices[ni];
        if (pidx == @intFromEnum(NodeIndex.none)) return false;
        const parent: NodeIndex = @enumFromInt(pidx);
        if (self.ast_ref.nodeTag(parent) != .assign) return false;
        return @intFromEnum(self.ast_ref.nodeData(parent).lhs) == ni;
    }

    /// The value type established by an evolving write.  For `=` it is the RHS
    /// type; for a compound assignment it is the result of the operator
    /// (`a += x` ≈ `a + x`): `+=` yields string/bigint/number/any by operand,
    /// the arithmetic/bitwise/shift forms yield number (or bigint), and the
    /// logical forms (`||=`/`&&=`/`??=`) are treated conservatively as `any`.
    fn evolvingWriteType(self: *Checker, w: EvolvingWrite) TypeId {
        if (w.op == .assign) return self.typeOf(w.rhs);
        const r = self.typeOf(w.rhs);
        return switch (w.op) {
            .add_assign => if (tymod.isAny(&self.store, r))
                tymod.ID_ANY
            else if (isStringish(&self.store, r))
                tymod.ID_STRING
            else if (isBigintish(&self.store, r))
                tymod.ID_BIGINT
            else
                tymod.ID_NUMBER,
            .logical_and_assign, .logical_or_assign, .nullish_assign => tymod.ID_ANY,
            else => if (isBigintish(&self.store, r)) tymod.ID_BIGINT else tymod.ID_NUMBER,
        };
    }

    /// Whether the var/let binding for `sym` has an initializer.  Evolving-any
    /// applies only to bindings declared *without* one (`var x;`); a binding
    /// with an initializer takes that initializer's type even when we can't
    /// resolve it (`var x = Array()` is `any[]`, not an evolving auto var).
    /// `const choice: Choice = Choice.One` — tsc narrows reads of an
    /// annotated, const-declared enum variable to the initializer's member
    /// type (`choice : Choice.One`).  Safe without flow analysis: a const has
    /// exactly one assignment.  Returns null to keep the declared type.
    fn narrowConstEnumAtUse(self: *Checker, sym: symbol_mod.SymbolId, use_node: NodeIndex, base: TypeId) ?TypeId {
        // Declared type must be enum-ish: a union of enum members, or a
        // (possibly alias-tagged) lone member type.
        const bt = self.store.get(base);
        const enum_base = switch (bt.kind) {
            .union_t => blk: {
                const ms = self.store.idsOf(bt.list_data);
                if (ms.len == 0) break :blk false;
                for (ms) |m| {
                    if (self.store.get(m).enum_name.len == 0) break :blk false;
                }
                break :blk true;
            },
            else => bt.enum_name.len > 0,
        };
        if (!enum_base) return null;
        const decl = self.semantic.symbols.getDeclNode(sym);
        if (decl == .none or decl == use_node) return null;
        // Walk decl identifier → declarator → const_decl.
        const parents = self.semantic.parent_indices;
        var declarator = decl;
        if (self.ast_ref.nodeTag(declarator) != .declarator) {
            const ni = declarator.toInt();
            if (ni >= parents.len) return null;
            const p = parents[ni];
            if (p == @intFromEnum(NodeIndex.none)) return null;
            declarator = @enumFromInt(p);
            if (self.ast_ref.nodeTag(declarator) != .declarator) return null;
        }
        {
            const di = declarator.toInt();
            if (di >= parents.len) return null;
            const dp = parents[di];
            if (dp == @intFromEnum(NodeIndex.none)) return null;
            if (self.ast_ref.nodeTag(@enumFromInt(dp)) != .const_decl) return null;
        }
        const init_node = self.ast_ref.nodeData(declarator).rhs;
        if (init_node == .none) return null;
        const init_ty = self.typeOf(init_node);
        if (self.store.get(init_ty).enum_name.len == 0) return null;
        return init_ty;
    }

    fn bindingHasInitializer(self: *Checker, sym: symbol_mod.SymbolId) bool {
        const decl = self.semantic.symbols.getDeclNode(sym);
        if (decl == .none) return false;
        var node = decl;
        if (self.ast_ref.nodeTag(node) != .declarator) {
            const ni = node.toInt();
            if (ni >= self.semantic.parent_indices.len) return false;
            const p = self.semantic.parent_indices[ni];
            if (p == @intFromEnum(NodeIndex.none)) return false;
            node = @enumFromInt(p);
            if (self.ast_ref.nodeTag(node) != .declarator) return false;
        }
        return self.ast_ref.nodeData(node).rhs != .none;
    }

    fn inferEvolvingType(self: *Checker, sym: symbol_mod.SymbolId, use_node: NodeIndex) ?TypeId {
        if (!self.evolving_index_built) self.buildEvolvingIndex();
        const symid = sym.toInt();
        if (self.bindingHasInitializer(sym)) return null;
        const list = self.evolving_assign_index.get(symid) orelse return null;
        if (list.items.len == 0) return null;
        if (self.evolving_in_progress.contains(symid)) return null;
        // Pure `=` write target → the binding's *declared* type, which for an
        // evolving auto variable renders as `any` regardless of what it evolves
        // to (`bc = b & c` reports `bc : any` even though every write is
        // number).  Compound `+=` targets are read-modify-writes and fall
        // through to the flow path below.
        if (self.isPlainAssignTarget(use_node)) return null;

        var reaches: [64]bool = undefined;
        @memset(&reaches, false);
        const m = @min(list.items.len, reaches.len);
        const writes = list.items[0..m];

        {
            // Read (or compound-assignment target) → reaching-definitions flow
            // type over PLAIN writes only; tsc keeps the prior narrowed type
            // across a compound op.
            const use_ni = use_node.toInt();
            const use_seg: u32 = if (use_ni < self.node_seg.len) self.node_seg[use_ni] else NONE_SEG;
            const use_pos = self.ast_ref.nodeSpan(use_node).start;
            if (use_seg != NONE_SEG) {
                if (self.semantic.code_path_result) |*cpr| {
                    if (self.computeReachingWrites(cpr, writes, reaches[0..m], use_seg, use_pos, use_node)) return null;
                } else {
                    for (writes, 0..) |w, i| reaches[i] = w.pos < use_pos and w.op == .assign;
                }
            } else {
                for (writes, 0..) |w, i| reaches[i] = w.pos < use_pos and w.op == .assign;
            }
        }

        self.evolving_in_progress.put(self.gpa, symid, {}) catch return null;
        defer _ = self.evolving_in_progress.remove(symid);
        var buf: [32]TypeId = undefined;
        var n: usize = 0;
        for (writes, 0..) |w, i| {
            if (!reaches[i]) continue;
            const raw = self.evolvingWriteType(w);
            if (tymod.isAny(&self.store, raw) or raw.eq(tymod.ID_UNKNOWN)) return null;
            // Restrict evolution to primitive write types (literals widened to
            // their base).  Non-primitive writes — arrays/tuples (TS's separate
            // evolving-array mechanism), objects, unions and named/aliased types
            // — engage structural/contextual/alias machinery we render
            // differently, so fall back to `any` for those.
            const widened = switch (self.store.get(raw).kind) {
                .string, .string_literal => tymod.ID_STRING,
                .number, .number_literal => tymod.ID_NUMBER,
                .bigint, .bigint_literal => tymod.ID_BIGINT,
                .boolean, .boolean_literal => tymod.ID_BOOLEAN,
                else => return null,
            };
            if (n < buf.len) {
                buf[n] = widened;
                n += 1;
            }
        }
        if (n == 0) return null;
        const u = self.store.unionOf(buf[0..n]) catch return null;
        if (tymod.isAny(&self.store, u)) return null;
        return u;
    }

    /// True when `node` is the receiver of an evolving-array mutation
    /// (`x.push(...)`/`x.unshift(...)`) or the object of an element assignment
    /// (`x[i] = v`).  At such a position TypeScript reports the auto-array type
    /// (`any[]`), not the finalized element-union type.
    fn isEvolvingArrayOpTarget(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        // Peel enclosing parentheses: `((x))[3] = …` / `(x).push(…)`.
        var ni = node.toInt();
        while (ni < parents.len) {
            const up = parents[ni];
            if (up == @intFromEnum(NodeIndex.none)) break;
            if (self.ast_ref.nodeTag(@as(NodeIndex, @enumFromInt(up))) != .grouping_expr) break;
            ni = up;
        }
        if (ni >= parents.len) return false;
        const pidx = parents[ni];
        if (pidx == @intFromEnum(NodeIndex.none)) return false;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        const md = self.ast_ref.nodeData(parent);
        if (@intFromEnum(md.lhs) != ni) return false; // node is the object
        if (ptag == .member_expr) {
            if (md.rhs == .none) return false;
            const method = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
            if (!std.mem.eql(u8, method, "push") and !std.mem.eql(u8, method, "unshift")) return false;
            const pi = parent.toInt();
            if (pi >= parents.len) return false;
            const gpi = parents[pi];
            if (gpi == @intFromEnum(NodeIndex.none)) return false;
            const gp: NodeIndex = @enumFromInt(gpi);
            return self.ast_ref.nodeTag(gp) == .call_expr and
                @intFromEnum(self.ast_ref.nodeData(gp).lhs) == pi;
        } else if (ptag == .computed_member_expr) {
            const pi = parent.toInt();
            if (pi >= parents.len) return false;
            const gpi = parents[pi];
            if (gpi == @intFromEnum(NodeIndex.none)) return false;
            const gp: NodeIndex = @enumFromInt(gpi);
            return self.ast_ref.nodeTag(gp) == .assign and
                @intFromEnum(self.ast_ref.nodeData(gp).lhs) == pi;
        }
        return false;
    }

    /// Fill `seg_reach_set` with every segment that can reach `target`
    /// (backward closure over prev + looped-prev edges).
    fn computeBackwardClosure(self: *Checker, cpr: anytype, target: u32) void {
        self.seg_reach_set.clearRetainingCapacity();
        self.seg_worklist.clearRetainingCapacity();
        if (target >= cpr.seg_count) return;
        self.seg_reach_set.put(self.gpa, target, {}) catch return;
        _ = self.pushPrevSegs(cpr, target);
        while (self.seg_worklist.pop()) |seg| {
            if (seg >= cpr.seg_count) continue;
            _ = self.pushPrevSegs(cpr, seg);
        }
    }

    /// Evolving-array: type a use of an auto-array `let x = []` binding.  A
    /// push-receiver / element-assign target reads as `any[]`; a pure read is
    /// `(union of element contributions reaching it)[]`, or `any[]` when none.
    /// A write at (`w_seg`,`w_pos`) reaches the use: earlier in the same
    /// segment, or in a CFG predecessor segment (closure precomputed in
    /// `seg_reach_set`).  Falls back to source order without CFG.
    fn writeReachesUse(self: *Checker, w_seg: u32, w_pos: u32, use_seg: u32, use_pos: u32, has_cfg: bool) bool {
        if (use_seg == NONE_SEG or w_seg == NONE_SEG or !has_cfg) return w_pos < use_pos;
        if (w_seg == use_seg) return w_pos < use_pos;
        return self.seg_reach_set.contains(w_seg);
    }

    fn inferEvolvingArrayType(self: *Checker, sym: symbol_mod.SymbolId, use_node: NodeIndex) ?TypeId {
        if (!self.evolving_index_built) self.buildEvolvingIndex();
        const symid = sym.toInt();
        if (!self.evolving_array_syms.contains(symid)) return null;
        // No element contributions anywhere → the array never evolves; leave
        // the declared empty-array type (`never[]`) untouched rather than
        // forcing `any[]`.
        const list = self.evolving_array_contribs.get(symid) orelse return null;
        if (list.items.len == 0) return null;

        const use_ni = use_node.toInt();
        const use_seg: u32 = if (use_ni < self.node_seg.len) self.node_seg[use_ni] else NONE_SEG;
        const use_pos = self.ast_ref.nodeSpan(use_node).start;
        const cpr_opt = self.semantic.code_path_result;
        if (cpr_opt) |*cpr| {
            if (use_seg != NONE_SEG) self.computeBackwardClosure(cpr, use_seg);
        }
        const has_cfg = cpr_opt != null;

        // The binding is an array at this use only if its initializer is `[]`
        // or a `x = []` reset reaches the use.  Before that (`let x;`
        // declaration, uses preceding the reset) it is the plain auto `any`.
        if (!self.evolving_array_init.contains(symid)) {
            const resets = self.evolving_array_resets.get(symid) orelse return null;
            var reached = false;
            for (resets.items) |r| {
                if (self.writeReachesUse(r.seg, r.pos, use_seg, use_pos, has_cfg)) {
                    reached = true;
                    break;
                }
            }
            if (!reached) return null;
        }

        const any_arr = self.store.arrayOf(tymod.ID_ANY) catch tymod.ID_ANY;
        if (self.isEvolvingArrayOpTarget(use_node)) return any_arr;
        if (self.evolving_in_progress.contains(symid)) return any_arr;

        self.evolving_in_progress.put(self.gpa, symid, {}) catch return any_arr;
        defer _ = self.evolving_in_progress.remove(symid);
        var buf: [32]TypeId = undefined;
        var n: usize = 0;
        for (list.items) |c| {
            const reaches = self.writeReachesUse(c.seg, c.pos, use_seg, use_pos, has_cfg);
            if (!reaches) continue;
            const raw = self.typeOf(c.rhs);
            const widened = switch (self.store.get(raw).kind) {
                .string_literal => tymod.ID_STRING,
                .number_literal => tymod.ID_NUMBER,
                .bigint_literal => tymod.ID_BIGINT,
                .boolean_literal => tymod.ID_BOOLEAN,
                else => raw,
            };
            if (n < buf.len) {
                buf[n] = widened;
                n += 1;
            }
        }
        if (n == 0) return any_arr;
        sortUnionByTypePriority(&self.store, buf[0..n]);
        const elem = self.store.unionOf(buf[0..n]) catch return any_arr;
        return self.store.arrayOf(elem) catch any_arr;
    }

    fn declaredTypeForSymbol(self: *Checker, sym: symbol_mod.SymbolId) TypeId {
        const cached = self.sym_types[sym.toInt()];
        if (!cached.eq(TypeId.none)) return cached;
        // Mark in-progress with .any so recursive lookups can't loop.
        self.sym_types[sym.toInt()] = tymod.ID_ANY;
        const decl_node = self.semantic.symbols.getDeclNode(sym);
        const ty = self.declaredTypeAtBinding(decl_node);
        self.sym_types[sym.toInt()] = ty;
        return ty;
    }

    /// Given a binding identifier node, find its declared TS type by
    /// reading the annotation attached to the identifier (parser stores
    /// the ts_type_annotation node in identifier.data.rhs), or by walking
    /// up to the declarator and falling back to the initializer.
    pub fn declaredTypeAtBinding(self: *Checker, binding: NodeIndex) TypeId {
        if (binding == .none) return tymod.ID_ANY;
        // Enum binding: the symbol's decl node is the ts_enum_decl itself
        // (the parser declares the enum name so forward references resolve).
        // Type its value side as the enum object shape — each member a
        // literal-typed prop — so `EnumName.Member` access types correctly.
        // Without this the symbol path would fall through to `any`, and
        // type-aware rules (strict-boolean-expressions, no-unsafe-enum-*)
        // would lose enum-ness. Mirrors the no-symbol fallback in
        // inferIdentifier.
        if (self.ast_ref.nodeTag(binding) == .ts_enum_decl) {
            // Enum values are typed as `any` to match TypeScript's runtime behavior.
            // Member access (like `EnumName.Member`) is handled specially in inferMember.
            return tymod.ID_ANY;
        }
        // Try to find a type annotation by peeling wrappers and checking the binding or its lhs.
        var node = binding;
        // Peel wrappers: assignment_pattern (default value), ts_parameter_property, rest_element.
        while (true) {
            const tag = self.ast_ref.nodeTag(node);
            if (tag == .assignment_pattern or tag == .ts_parameter_property) {
                node = self.ast_ref.nodeData(node).lhs;
            } else if (tag == .rest_element) {
                // rest_element: annotation is on the rest_element itself
                const data = self.ast_ref.nodeData(node);
                if (data.rhs != .none and self.ast_ref.nodeTag(data.rhs) == .ts_type_annotation) {
                    const ty_node = self.ast_ref.nodeData(data.rhs).lhs;
                    self.type_pos_depth += 1;
                    const ty = self.resolveTypeNode(ty_node);
                    self.type_pos_depth -= 1;
                    return ty;
                }
                // If no annotation, peel to lhs
                node = data.lhs;
            } else if (tag == .declarator) {
                // declarator: check the lhs (which is the identifier)
                const data = self.ast_ref.nodeData(node);
                node = data.lhs;
            } else {
                break;
            }
        }
        // Check the final node for a direct annotation
        if (node != .none) {
            const bd = self.ast_ref.nodeData(node);
            if (bd.rhs != .none and self.ast_ref.nodeTag(bd.rhs) == .ts_type_annotation) {
                const ty_node = self.ast_ref.nodeData(bd.rhs).lhs;
                self.type_pos_depth += 1;
                var ty = self.resolveTypeNode(ty_node);
                self.type_pos_depth -= 1;
                // Optional parameter (`x?: T`) — parser marks the identifier
                // by setting lhs to `.root`.  TypeScript always types optional
                // params as `T | undefined` regardless of strictNullChecks.
                if (bd.lhs == .root) {
                    const ids = [_]TypeId{ ty, tymod.ID_UNDEFINED };
                    ty = self.store.unionOf(&ids) catch ty;
                }
                return ty;
            }
        }
        const parents = self.semantic.parent_indices;
        const bidx = binding.toInt();
        if (bidx >= parents.len) return tymod.ID_ANY;
        const pidx = parents[bidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return tymod.ID_ANY;
        const parent: NodeIndex = @enumFromInt(pidx);
        const ptag = self.ast_ref.nodeTag(parent);
        switch (ptag) {
            // When the decl_node is ts_enum_member (binding is the enum member node),
            // the parent is ts_enum_decl. Return the member's E.Name type.
            .ts_enum_decl => {
                if (self.ast_ref.nodeTag(binding) == .ts_enum_member) {
                    const mdata = self.ast_ref.nodeData(binding);
                    if (mdata.lhs != .none) {
                        const member_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
                        const pdata = self.ast_ref.nodeData(parent);
                        if (pdata.lhs != .none) {
                            const ged = self.ast_ref.extraData(ast.EnumData, @intFromEnum(pdata.lhs));
                            const enum_name = self.ast_ref.tokenText(ged.name);
                            if (self.buildEnumObjectType(enum_name)) |obj_type| {
                                const ot = self.store.get(obj_type);
                                if (ot.kind == .object_t) {
                                    for (self.store.propsOf(ot.object_props)) |p| {
                                        if (std.mem.eql(u8, p.name, member_name)) {
                                            const pt = self.store.get(p.type_id);
                                            if (pt.enum_name.len > 0) return self.enumMemberDeclType(p.type_id);
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return tymod.ID_ANY;
            },
            .declarator => {
                const data = self.ast_ref.nodeData(parent);
                // Check if the identifier has a type annotation first.
                // If it does, the declared type takes precedence over the initializer type.
                if (data.lhs != .none) {
                    const id_data = self.ast_ref.nodeData(data.lhs);
                    if (id_data.rhs != .none and self.ast_ref.nodeTag(id_data.rhs) == .ts_type_annotation) {
                        const ty_node = self.ast_ref.nodeData(id_data.rhs).lhs;
                        return self.resolveTypeNode(ty_node);
                    }
                }
                // JSDoc `/** @type {T} */ var x = …` — the tag supplies the
                // declared type (JS only).  Keyed by the enclosing var-decl.
                if (self.checker_opts.is_js_file) {
                    if (!self.jsdoc_built) self.buildJsdoc();
                    if (self.jsdoc_vars.count() > 0) {
                        const di = parent.toInt();
                        if (di < self.semantic.parent_indices.len) {
                            const vd = self.semantic.parent_indices[di];
                            if (vd != @intFromEnum(NodeIndex.none)) {
                                if (self.jsdoc_vars.get(vd)) |ts| {
                                    return self.parseJsdocType(ts);
                                }
                            }
                        }
                    }
                }
                if (data.rhs != .none) {
                    const raw = self.typeOf(data.rhs);
                    const t = self.store.get(raw);
                    // Array/tuple literals are always widened to T[] — TypeScript
                    // widens `['c', 'd']` to `string[]` for both let and const
                    // (only `as const` produces a readonly tuple literal type).
                    if (t.kind == .tuple_t) {
                        if (t.name.len > 0) return raw; // readonly tuple from `as const` — preserve
                        const elems = self.store.idsOf(t.list_data);
                        if (elems.len == 0) {
                            return self.store.arrayOf(tymod.ID_NEVER) catch raw;
                        }
                        // Widen primitive literals in the tuple elements before unioning
                        var widened_buf: [32]TypeId = undefined;
                        const widen_count = @min(elems.len, widened_buf.len);
                        for (0..widen_count) |j| {
                            const elem_t = self.store.get(elems[j]);
                            const widened = switch (elem_t.kind) {
                                .string_literal => tymod.ID_STRING,
                                .number_literal => tymod.ID_NUMBER,
                                .bigint_literal => tymod.ID_BIGINT,
                                .boolean_literal => tymod.ID_BOOLEAN,
                                else => elems[j],
                            };
                            widened_buf[j] = widened;
                        }
                        sortUnionByTypePriority(&self.store, widened_buf[0..widen_count]);
                        const elem_t = self.store.unionOf(widened_buf[0..widen_count]) catch elems[0];
                        return self.store.arrayOf(elem_t) catch raw;
                    }
                    // Primitive literals are widened to their base type for
                    // let/var declarations; const preserves the literal type.
                    const decl_idx = parent.toInt();
                    const is_mutable = blk: {
                        if (decl_idx >= parents.len) break :blk false;
                        const gidx = parents[decl_idx];
                        if (gidx == @intFromEnum(NodeIndex.none)) break :blk false;
                        const gtag = self.ast_ref.nodeTag(@enumFromInt(gidx));
                        break :blk gtag == .let_decl or gtag == .var_decl;
                    };
                    const is_as_const = blk: {
                        if (!is_mutable) break :blk false;
                        const init_tag = self.ast_ref.nodeTag(data.rhs);
                        if (init_tag != .ts_as_expr) break :blk false;
                        const init_data = self.ast_ref.nodeData(data.rhs);
                        if (init_data.rhs == .none) break :blk false;
                        if (self.ast_ref.nodeTag(init_data.rhs) != .ts_type_reference) break :blk false;
                        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(init_data.rhs));
                        break :blk std.mem.eql(u8, name, "const");
                    };
                    if (is_mutable and !is_as_const) {
                        // In non-strict mode, null/undefined initializers widen to any.
                        // `var x = null` → x: any (TypeScript's null-widening rule).
                        if (!self.checker_opts.strict_null_checks) {
                            if (t.kind == .null_t or t.kind == .undefined_t) return tymod.ID_ANY;
                        }
                        // Enum members widen member-wise on let/var: FRESH
                        // members (direct `E.B` accesses, through unannotated
                        // const chains) widen to the full enum type E, which
                        // absorbs any sibling members; non-fresh members (from
                        // annotated declarations) keep the member type.
                        enum_widen: {
                            const is_enumish = t.enum_name.len > 0 or
                                (t.kind == .union_t and blk: {
                                    const ms = self.store.idsOf(t.list_data);
                                    if (ms.len == 0) break :blk false;
                                    for (ms) |m| {
                                        if (self.store.get(m).enum_name.len == 0) break :blk false;
                                    }
                                    break :blk true;
                                });
                            if (!is_enumish) break :enum_widen;
                            var set = EnumFreshSet{};
                            if (!self.collectEnumFreshMembers(data.rhs, 0, &set)) break :enum_widen;
                            if (set.n == 0 or set.ename.len == 0) break :enum_widen;
                            var any_fresh = false;
                            for (set.fresh[0..set.n]) |f| {
                                if (f) any_fresh = true;
                            }
                            // Any fresh member widens to E, and E absorbs the
                            // rest of the same enum's members.
                            if (any_fresh) {
                                if (self.buildEnumUnionType(set.ename)) |eu| return eu;
                            }
                        }
                        // Handle primitive literals
                        const widened_prim = switch (t.kind) {
                            .string_literal => tymod.ID_STRING,
                            .number_literal => tymod.ID_NUMBER,
                            .bigint_literal => tymod.ID_BIGINT,
                            // Boolean literals are widened only for direct literals
                            // (true/false) or `!expr` — not for &&/|| results which
                            // propagate non-widening literal types from parameters.
                            .boolean_literal => blk: {
                                const init_tag = self.ast_ref.nodeTag(data.rhs);
                                break :blk if (init_tag == .boolean_literal or
                                    init_tag == .logical_not)
                                    tymod.ID_BOOLEAN
                                else
                                    raw;
                            },
                            else => raw,
                        };
                        if (widened_prim != raw) return widened_prim;

                        // Handle object literals with literal properties
                        if (t.kind == .object_t) {
                            const props = self.store.propsOf(t.object_props);
                            var has_literals = false;
                            for (props) |p| {
                                const pt = self.store.get(p.type_id);
                                if (pt.kind == .string_literal or pt.kind == .number_literal or pt.kind == .boolean_literal) {
                                    has_literals = true;
                                    break;
                                }
                            }
                            if (has_literals) {
                                var buf: [16]tymod.ObjectProp = undefined;
                                var n: usize = 0;
                                for (props) |p| {
                                    if (n >= buf.len) break;
                                    const pt = self.store.get(p.type_id);
                                    const widened_prop_ty = switch (pt.kind) {
                                        .string_literal => tymod.ID_STRING,
                                        .number_literal => tymod.ID_NUMBER,
                                        .boolean_literal => tymod.ID_BOOLEAN,
                                        else => p.type_id,
                                    };
                                    buf[n] = p;
                                    buf[n].type_id = widened_prop_ty;
                                    n += 1;
                                }
                                return self.store.objectOf(buf[0..n]) catch raw;
                            }
                        }
                        return raw;
                    }
                    return raw;
                }
                // No annotation and no initializer: check if this is a for-in binding.
                // `for (const x in obj)` — x is always string (a property key).
                if (self.isForInLoopBinding(parent)) return tymod.ID_STRING;
                // `for (const x of arr)` — x is arr's element type.
                if (self.forOfBindingElementType(parent)) |t| return t;
                return tymod.ID_UNKNOWN;
            },
            .assignment_pattern => {
                // Function parameter with default value: `a: T = default_value`.
                // Type annotation is on the identifier (lhs), not the default value (rhs).
                // Return the annotation type if present; otherwise unknown (don't infer from default).
                const data = self.ast_ref.nodeData(parent);
                if (data.lhs != .none) {
                    const id_data = self.ast_ref.nodeData(data.lhs);
                    if (id_data.rhs != .none and self.ast_ref.nodeTag(id_data.rhs) == .ts_type_annotation) {
                        const ty_node = self.ast_ref.nodeData(id_data.rhs).lhs;
                        var ty = self.resolveTypeNode(ty_node);
                        // Optional parameter (`x?: T`) — parser marks the identifier
                        // by setting lhs to `.root`.  Union the annotation type
                        // with `undefined` to match TS's behavior.
                        if (id_data.lhs == .root) {
                            const ids = [_]TypeId{ ty, tymod.ID_UNDEFINED };
                            ty = self.store.unionOf(&ids) catch ty;
                        }
                        return ty;
                    }
                }
                // No annotation: for simple literal defaults, return the base type.
                // Only apply this for simple identifiers (not destructuring patterns).
                if (data.lhs != .none and self.ast_ref.nodeTag(data.lhs) == .identifier and data.rhs != .none) {
                    const rhs_tag = self.ast_ref.nodeTag(data.rhs);
                    switch (rhs_tag) {
                        .string_literal => return tymod.ID_STRING,
                        .number_literal => return tymod.ID_NUMBER,
                        .bigint_literal => return tymod.ID_BIGINT,
                        .boolean_literal => return tymod.ID_BOOLEAN,
                        else => {},
                    }
                    // Function/arrow defaults (`cb = function(){}`, `cb = () => 1`):
                    // tsc uses the inferred function type as the parameter type.
                    switch (rhs_tag) {
                        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                        .arrow_fn, .async_arrow_fn => return self.typeOf(data.rhs),
                        else => {},
                    }
                    // Composed default (e.g. `x = arr[0]`): infer, then widen
                    // fresh literal types to their base, other non-literals → unknown.
                    const raw = self.typeOf(data.rhs);
                    return switch (self.store.get(raw).kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .bigint_literal => tymod.ID_BIGINT,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        else => tymod.ID_UNKNOWN,
                    };
                }
                return tymod.ID_UNKNOWN;
            },
            .rest_element => {
                // `...a: T` — type annotation lives on the rest_element
                // (parser stores `: T` in rhs).  Resolve and return.
                const data = self.ast_ref.nodeData(parent);
                if (data.rhs != .none and self.ast_ref.nodeTag(data.rhs) == .ts_type_annotation) {
                    const ty_node = self.ast_ref.nodeData(data.rhs).lhs;
                    return self.resolveTypeNode(ty_node);
                }
                // Unannotated rest *parameter* → any[].  Rest elements inside
                // destructuring patterns keep their pattern-driven inference.
                // Accessor params have no parent link (semantic doesn't wire
                // them) — a parentless rest_element can only be a param.
                const rest_orphan = blk: {
                    const ridx = parent.toInt();
                    if (ridx >= parents.len) break :blk false;
                    break :blk parents[ridx] == @intFromEnum(NodeIndex.none);
                };
                if (rest_orphan or self.isFunctionParamNode(parent)) {
                    return self.store.arrayOf(tymod.ID_ANY) catch tymod.ID_UNKNOWN;
                }
                return tymod.ID_UNKNOWN;
            },
            // Function declarations: build a function_t from the
            // FnData (params + return).  Caller-side call inference
            // can then resolve the return type and check arg types.
            // For overload signatures (no body), collect ALL call-visible
            // overloads so functionAssertionInfo can correctly detect
            // whether a non-asserting overload exists.
            .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
            .ts_declare_function => {
                const pdata = self.ast_ref.nodeData(parent);
                if (pdata.lhs != .none) {
                    const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(pdata.lhs));
                    // Check if the binding is actually a parameter of this function.
                    // If so, return ID_ANY for an unannotated parameter rather than the function's type.
                    if (fd.params <= fd.params_end and fd.params_end <= self.ast_ref.extra_data.len) {
                        const params = self.ast_ref.extra_data[fd.params..fd.params_end];
                        for (params) |raw| {
                            if (raw == binding.toInt()) {
                                // The binding is a parameter of this function.
                                // A JSDoc `@param {T}` tag supplies the type in JS.
                                if (self.jsdocParamBindingType(binding)) |jt| return jt;
                                // Unannotated parameters should be any, not the function type.
                                // But if the binding is a parameter wrapper (assignment_pattern, rest_element, etc.),
                                // those cases should have been handled by their respective switch arms.
                                // This case handles simple parameter identifiers with no annotation.
                                return tymod.ID_ANY;
                            }
                        }
                    }
                    if (fd.name != .none) {
                        // An overloaded function's type is its overload signatures —
                        // exposed on EVERY declaration including the implementation
                        // (with a body), per TS. functionTypeFromAllOverloads only
                        // collects no-body signature decls, so it returns null for a
                        // plain single-bodied function → falls through to its own type.
                        const fn_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(fd.name));
                        if (self.functionTypeFromAllOverloads(fn_name)) |t| return t;
                    }
                }
                return self.functionTypeFromFnDecl(parent);
            },
            // Class member keys: return the member's type so that
            // `typeOf(method_key_ident)` resolves correctly via the symbol path.
            .method_def, .computed_method_def => {
                const pdata = self.ast_ref.nodeData(parent);
                if (pdata.lhs != binding) return tymod.ID_ANY;
                // For overloaded methods, return the merged multi-sig type so
                // every declaration shows the full overload set, matching tsc.
                const key_tag2 = self.ast_ref.nodeTag(pdata.lhs);
                if (key_tag2 == .identifier or key_tag2 == .property_ident) {
                    const mname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pdata.lhs));
                    if (mname.len > 0) {
                        if (self.classMethodTypeAtDecl(parent, mname)) |merged| return merged;
                    }
                }
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(pdata.rhs));
                const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                const mres2 = self.buildFunctionType(md.params_start, md.params_end, md.return_type, md.body, is_async, is_generator);
                if (md.type_params < md.type_params_end)
                    self.registerFnTypeParams(mres2, md.type_params, md.type_params_end);
                return mres2;
            },
            .getter_def => {
                const pdata = self.ast_ref.nodeData(parent);
                if (pdata.lhs != binding) return tymod.ID_ANY;
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(pdata.rhs));
                const fn_ty = self.buildFunctionType(md.params_start, md.params_end, md.return_type, md.body, false, false);
                const ft = self.store.get(fn_ty);
                if (ft.kind == .function_t) {
                    const sigs = self.store.signaturesOf(ft.signatures);
                    if (sigs.len > 0) return sigs[0].return_type;
                }
                return tymod.ID_ANY;
            },
            .setter_def => {
                // Both the setter's *name* and its *parameter* carry the
                // accessor property type: the annotated param type if present,
                // otherwise the paired getter's (body-inferred) return type.
                const pdata = self.ast_ref.nodeData(parent);
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(pdata.rhs));
                const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
                const is_name = pdata.lhs == binding;
                var is_param = false;
                if (md.params_start < md.params_end and md.params_end <= ext_len) {
                    const param: NodeIndex = @enumFromInt(self.ast_ref.extra_data[md.params_start]);
                    is_param = param == binding or
                        (self.ast_ref.nodeTag(param) == .assignment_pattern and
                            self.ast_ref.nodeData(param).lhs == binding);
                    if (is_name or is_param) {
                        if (self.paramHasAnnotation(param)) {
                            const pty = self.paramDeclaredType(param);
                            if (!pty.eq(tymod.ID_UNKNOWN)) return pty;
                        }
                    }
                }
                if (!is_name and !is_param) return tymod.ID_ANY;
                if (pdata.lhs != .none) {
                    const ntag = self.ast_ref.nodeTag(pdata.lhs);
                    if (ntag == .identifier or ntag == .property_ident) {
                        const pname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pdata.lhs));
                        if (self.pairedGetterReturnType(parent, pname)) |t| return t;
                    }
                }
                return tymod.ID_ANY;
            },
            .property_def => {
                const pdata = self.ast_ref.nodeData(parent);
                if (pdata.lhs != binding) return tymod.ID_ANY;
                const pd = self.ast_ref.extraData(ast.PropertyData, @intFromEnum(pdata.rhs));
                if (pd.type_annotation != .none and
                    self.ast_ref.nodeTag(pd.type_annotation) == .ts_type_annotation)
                {
                    const ty_node = self.ast_ref.nodeData(pd.type_annotation).lhs;
                    return self.resolveTypeNode(ty_node);
                }
                if (pd.value != .none) {
                    const raw = self.typeOf(pd.value);
                    const t = self.store.get(raw);
                    return switch (t.kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        .bigint_literal => tymod.ID_BIGINT,
                        else => raw,
                    };
                }
                return tymod.ID_ANY;
            },
            // The class/interface/type-alias name identifier's declared type
            // IS the named type itself.  Return a type_ref so that
            // `typeOf(C_decl_node)` serializes as "C" (matching the TypeScript
            // baseline format) instead of falling through to any.
            // NOTE: this also makes all identifier REFERENCES to class C return
            // type_ref("C") via the sym_types cache in declaredTypeForSymbol.
            .class_decl, .ts_interface_decl => {
                const tok = self.ast_ref.nodeMainToken(binding);
                const name = self.ast_ref.tokenText(tok);
                if (name.len > 0) return self.store.typeRef(name, &.{}) catch tymod.ID_ANY;
                return tymod.ID_ANY;
            },
            // For generic type aliases like `type Tree<T> = ...`, the declared
            // type of the alias NAME is `Tree<T>` (with type param placeholders),
            // not bare `Tree`.
            .ts_type_alias_decl => {
                const tok = self.ast_ref.nodeMainToken(binding);
                const name = self.ast_ref.tokenText(tok);
                if (name.len == 0) return tymod.ID_ANY;
                const dd = self.ast_ref.nodeData(parent);
                if (dd.lhs == .none) return self.store.typeRef(name, &.{}) catch tymod.ID_ANY;
                const ad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(dd.lhs));
                if (ad.type_params >= ad.type_params_end) {
                    return self.store.typeRef(name, &.{}) catch tymod.ID_ANY;
                }
                const n_params = ad.type_params_end - ad.type_params;
                var args_buf: [8]TypeId = undefined;
                const count = @min(n_params, @as(u32, args_buf.len));
                for (0..count) |i| {
                    const tp_node: NodeIndex = @enumFromInt(self.ast_ref.extra_data[ad.type_params + @as(u32, @intCast(i))]);
                    const tp_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp_node));
                    args_buf[i] = self.store.typeParam(tp_name, TypeId.none) catch return tymod.ID_ANY;
                }
                return self.store.typeRef(name, args_buf[0..count]) catch tymod.ID_ANY;
            },
            // Enum member key: `A` in `enum E1 { A = 1 }` has type `E1.A`.
            .ts_enum_member => {
                const pdata = self.ast_ref.nodeData(parent);
                if (pdata.lhs != binding) return tymod.ID_ANY; // binding is the initializer
                const member_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(binding));
                // Grandparent must be ts_enum_decl.
                const gidx = if (parent.toInt() < parents.len) parents[parent.toInt()] else @intFromEnum(NodeIndex.none);
                if (gidx == @intFromEnum(NodeIndex.none)) return tymod.ID_ANY;
                const grandparent: NodeIndex = @enumFromInt(gidx);
                if (self.ast_ref.nodeTag(grandparent) != .ts_enum_decl) return tymod.ID_ANY;
                const gdata = self.ast_ref.nodeData(grandparent);
                if (gdata.lhs == .none) return tymod.ID_ANY;
                const ged = self.ast_ref.extraData(ast.EnumData, @intFromEnum(gdata.lhs));
                const enum_name = self.ast_ref.tokenText(ged.name);
                if (self.buildEnumObjectType(enum_name)) |obj_type| {
                    const ot = self.store.get(obj_type);
                    if (ot.kind == .object_t) {
                        for (self.store.propsOf(ot.object_props)) |p| {
                            if (std.mem.eql(u8, p.name, member_name)) return p.type_id;
                        }
                    }
                }
                return tymod.ID_ANY;
            },
            // Function/method/getter/setter parameter, class field, etc.
            // We don't resolve these structurally yet — return unknown
            // rather than any so unsafe-* rules don't spuriously fire.
            else => {
                // Pattern binding context: walk up through pattern parents to find
                // a declarator with an RHS we can infer the binding's type from.
                // This handles destructuring like `[x, y] = [1, 2]` where `y`'s
                // parent chain is pattern → pattern → declarator, but we need to
                // infer from the declarator's RHS.
                if (self.inferTypeFromDestructuringPattern(binding)) |t| return t;
                // Annotated destructured parameter: `function f({ a: x }: T)` —
                // x's type comes from T navigated by the pattern path.
                if (self.destructuredParamBindingType(binding)) |t| return t;
                // JSDoc-annotated (possibly destructured) parameter.
                if (self.jsdocParamBindingType(binding)) |t| return t;

                // Contextual typing: an un-annotated arrow/fn-expr parameter
                // that's the predicate of an array method gets the array's
                // element type.  `arr.some(x => x)` → x has type arr's
                // element.
                if (self.contextualArrayPredicateParamType(binding)) |t| return t;
                // Generic contextual typing: arrow callback passed to a
                // function whose parameter has a function type.  Walk
                // the callee's signature to find the matching arg slot's
                // param type.
                if (self.contextualCallbackParamType(binding)) |t| return t;
                // Promise rejection callback: `p.catch(e => …)` (arg 0) or
                // `p.then(onF, e => …)` (arg 1) — `e` is the rejection reason,
                // contextually `any` (lib.es5 onrejected is `(reason: any)`).
                if (self.contextualPromiseRejectionParamType(binding)) |t| return t;
                // For-in destructuring: `for (var [a, b] in obj)` — all bindings are string.
                if (self.isForInLoopBinding(binding)) return tymod.ID_STRING;
                // For-of simple binding: `for (var x of arr)` — element type.
                if (self.forOfBindingElementType(binding)) |t| return t;
                return tymod.ID_ANY;
            },
        }
    }

    /// True when the parameter carries an explicit type annotation. Used to
    /// distinguish an un-annotated param (defaults to unknown) from one
    /// explicitly annotated `: unknown`, so contextual typing only fills the
    /// former.
    fn paramHasAnnotation(self: *Checker, param: NodeIndex) bool {
        var node = param;
        if (self.ast_ref.nodeTag(node) == .assignment_pattern) node = self.ast_ref.nodeData(node).lhs;
        if (self.ast_ref.nodeTag(node) == .ts_parameter_property) node = self.ast_ref.nodeData(node).lhs;
        const d = self.ast_ref.nodeData(node);
        return d.rhs != .none and self.ast_ref.nodeTag(d.rhs) == .ts_type_annotation;
    }

    /// Peel parameter wrappers (default value, parameter property, rest) to the
    /// inner binding target. Object/array patterns are left intact.
    fn peelParamWrappers(self: *Checker, node: NodeIndex) NodeIndex {
        var n = node;
        while (true) {
            switch (self.ast_ref.nodeTag(n)) {
                .assignment_pattern, .ts_parameter_property, .rest_element => n = self.ast_ref.nodeData(n).lhs,
                else => return n,
            }
        }
    }

    /// Contextual typing for Promise rejection callbacks. The first parameter
    /// of `promise.catch(cb)` (the sole arg) or `promise.then(onF, onR)` (the
    /// second arg) is the rejection `reason`, which lib.es5 types `any`. Guarded
    /// by a Promise-typed receiver so non-Promise `.then`/`.catch` methods keep
    /// their declared param types.
    fn contextualPromiseRejectionParamType(self: *Checker, binding: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const bidx = binding.toInt();
        if (bidx >= parents.len) return null;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        // binding → arrow/fn-expr (the callback).
        var cur = parents[bidx];
        if (cur == NONE) return null;
        var fn_node: NodeIndex = .none;
        var depth: u32 = 0;
        while (cur != NONE and depth < 8) : ({ cur = parents[cur]; depth += 1; }) {
            switch (self.ast_ref.nodeTag(@enumFromInt(cur))) {
                .arrow_fn, .async_arrow_fn, .fn_expr, .async_fn_expr => { fn_node = @enumFromInt(cur); break; },
                else => {},
            }
        }
        if (fn_node == .none) return null;
        // binding must be the callback's FIRST parameter.
        var pstart: u32 = 0;
        var pend: u32 = 0;
        switch (self.ast_ref.nodeTag(fn_node)) {
            .arrow_fn, .async_arrow_fn => {
                const fd_d = self.ast_ref.nodeData(fn_node);
                if (fd_d.lhs == .none) return null;
                const adp = self.ast_ref.extraData(ast.ArrowData, @intFromEnum(fd_d.lhs));
                pstart = adp.params_start; pend = adp.params_end;
            },
            else => {
                const fd_d = self.ast_ref.nodeData(fn_node);
                if (fd_d.lhs == .none) return null;
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(fd_d.lhs));
                pstart = fd.params; pend = fd.params_end;
            },
        }
        if (pend <= pstart or pend > self.ast_ref.extra_data.len) return null;
        const params = self.ast_ref.extra_data[pstart..pend];
        // Accept `binding` whether it was passed as the raw first-param node
        // (from buildSignatureRaw) or the inner identifier (from the binding
        // resolver) — peel default / parameter-property / rest on both sides.
        if (self.peelParamWrappers(@enumFromInt(params[0])) != self.peelParamWrappers(binding)) return null;
        // The callback must be an argument of a `<recv>.catch(…)` / `<recv>.then(…)` call.
        const fn_parent = parents[fn_node.toInt()];
        if (fn_parent == NONE) return null;
        const call_node: NodeIndex = @enumFromInt(fn_parent);
        if (self.ast_ref.nodeTag(call_node) != .call_expr) return null;
        const cd = self.ast_ref.nodeData(call_node);
        var callee = cd.lhs;
        while (self.ast_ref.nodeTag(callee) == .grouping_expr) callee = self.ast_ref.nodeData(callee).lhs;
        const callee_tag = self.ast_ref.nodeTag(callee);
        if (callee_tag != .member_expr and callee_tag != .optional_member_expr) return null;
        const md = self.ast_ref.nodeData(callee);
        if (md.rhs == .none) return null;
        const method = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
        const reject_slot: usize = if (std.mem.eql(u8, method, "catch")) 0
            else if (std.mem.eql(u8, method, "then")) 1
            else return null;
        if (cd.rhs == .none) return null;
        const sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(cd.rhs));
        if (sr.start >= sr.end or sr.end > self.ast_ref.extra_data.len) return null;
        const args = self.ast_ref.extra_data[sr.start..sr.end];
        if (reject_slot >= args.len) return null;
        if (args[reject_slot] != fn_node.toInt()) return null;
        // Receiver must be a Promise.
        if (!tymod.isPromiseRef(&self.store, self.typeOf(md.lhs))) return null;
        return tymod.ID_ANY;
    }

    /// Returns true if `node` is a declaration binding inside a `for_in_stmt`.
    /// Walks up through pattern/declarator/var-decl ancestors up to a small depth.
    /// For-in bindings have no initializer and should be typed as `string` (property keys).
    fn isForInLoopBinding(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var cur: u32 = if (node.toInt() < parents.len) parents[node.toInt()] else NONE;
        var depth: u32 = 0;
        while (cur != NONE and depth < 8) : (depth += 1) {
            const p: NodeIndex = @enumFromInt(cur);
            switch (self.ast_ref.nodeTag(p)) {
                .for_in_stmt => return true,
                // Stop at other statement types that cannot contain a for_in_stmt binding.
                .for_of_stmt, .for_await_of_stmt, .for_stmt,
                .while_stmt, .do_while_stmt,
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                .arrow_fn, .async_arrow_fn,
                .block_stmt => return false,
                else => {},
            }
            cur = if (p.toInt() < parents.len) parents[p.toInt()] else NONE;
        }
        return false;
    }

    /// True when `node` sits directly in a function-like declaration's
    /// parameter list (its semantic parent is the function node itself).
    fn isFunctionParamNode(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return false;
        const pidx = parents[nidx];
        if (pidx == @intFromEnum(NodeIndex.none)) return false;
        return switch (self.ast_ref.nodeTag(@enumFromInt(pidx))) {
            .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
            .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
            .arrow_fn, .async_arrow_fn, .ts_declare_function,
            .method_def, .computed_method_def, .constructor_def,
            .getter_def, .setter_def, .computed_getter_def, .computed_setter_def,
            => true,
            else => false,
        };
    }

    /// If `node` is (inside) the declaration binding of a `for...of` loop,
    /// return the element type of the iterated expression:
    /// `for (const x of arr)` → arr's element type, `of "str"` → string.
    fn forOfBindingElementType(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var child = node;
        var cur: u32 = if (node.toInt() < parents.len) parents[node.toInt()] else NONE;
        var depth: u32 = 0;
        while (cur != NONE and depth < 8) : (depth += 1) {
            const p: NodeIndex = @enumFromInt(cur);
            switch (self.ast_ref.nodeTag(p)) {
                .for_of_stmt, .for_await_of_stmt => {
                    const data = self.ast_ref.nodeData(p);
                    if (data.lhs == .none) return null;
                    const fd = self.ast_ref.extraData(ast.ForInOfData, @intFromEnum(data.lhs));
                    if (fd.binding != child) return null; // reached via expr/body subtree
                    // `for (const v of [])` — tsc types v as any, not undefined.
                    if (self.ast_ref.nodeTag(fd.expr) == .array_literal) {
                        const ad = self.ast_ref.nodeData(fd.expr);
                        if (self.directRange(ad.lhs, ad.rhs)) |elems| {
                            if (elems.len == 0) return tymod.ID_ANY;
                        } else return tymod.ID_ANY;
                    }
                    const iter_ty = self.typeOf(fd.expr);
                    const it = self.store.get(iter_ty);
                    if (it.kind == .string or it.kind == .string_literal) return tymod.ID_STRING;
                    return self.elementTypeOf(iter_ty);
                },
                // Destructured for-of bindings (`for (const [a, b] of …)`) need
                // per-slot types, not the whole element type — bail.
                .array_pattern, .object_pattern, .rest_element,
                .for_in_stmt, .for_stmt, .while_stmt, .do_while_stmt,
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                .arrow_fn, .async_arrow_fn,
                .block_stmt => return null,
                else => {},
            }
            child = p;
            cur = if (p.toInt() < parents.len) parents[p.toInt()] else NONE;
        }
        return null;
    }

    /// Walk up through pattern parents (array/object patterns) to find
    /// a declarator with an RHS, then infer the binding's type from the RHS.
    /// This handles destructuring patterns like `[x, y] = [1, 2]` where `y`'s
    /// parent is inside a pattern, not directly the declarator.
    // ── JSDoc type annotations (JS files) ───────────────────────────────────

    /// Scan the source for `/** … */` JSDoc blocks and associate each with the
    /// declaration that immediately follows it, harvesting `@param`/`@returns`/
    /// `@type` type strings.  Lazy, once.
    fn buildJsdoc(self: *Checker) void {
        self.jsdoc_built = true;
        // JSDoc type tags only supply types in JS files; `.ts` ignores them.
        if (!self.checker_opts.is_js_file) return;
        const src = self.ast_ref.source;
        if (src.len < 4) return;
        var i: usize = 0;
        while (i + 2 < src.len) {
            // Find a JSDoc opener `/**`.
            if (src[i] == '/' and src[i + 1] == '*' and src[i + 2] == '*') {
                const block_start = i;
                var j = i + 3;
                while (j + 1 < src.len and !(src[j] == '*' and src[j + 1] == '/')) : (j += 1) {}
                const block_end = @min(j + 2, src.len);
                const block = src[block_start..block_end];
                // The declaration this block documents starts at the next token
                // after the block (skipping trivia).
                const decl_node = self.declAfterPos(block_end) orelse {
                    i = block_end;
                    continue;
                };
                self.attachJsdoc(block, decl_node);
                i = block_end;
            } else i += 1;
        }
    }

    /// First declaration-like node whose span starts at/after `pos` (and is the
    /// closest such).  Used to bind a JSDoc block to what it documents.
    fn declAfterPos(self: *Checker, pos: usize) ?NodeIndex {
        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var best: NodeIndex = .none;
        var best_start: usize = std.math.maxInt(usize);
        var n: u32 = 1;
        while (n < total) : (n += 1) {
            const ni: NodeIndex = @enumFromInt(n);
            switch (self.ast_ref.nodeTag(ni)) {
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .var_decl, .let_decl, .const_decl, .class_decl,
                .ts_declare_function, .expression_stmt => {},
                else => continue,
            }
            const span = self.ast_ref.nodeSpan(ni);
            if (span.start < pos) continue;
            if (span.start < best_start) {
                best_start = span.start;
                best = ni;
            }
        }
        return if (best == .none) null else best;
    }

    /// Parse the `@param`/`@returns`/`@type` tags out of a JSDoc block and
    /// attach the type strings to `decl`.
    fn attachJsdoc(self: *Checker, block: []const u8, decl: NodeIndex) void {
        // Resolve the function node (a var-decl `const f = function(){}` /
        // arrow documents the inner function for @param/@returns).
        const fn_node = self.jsdocFunctionOf(decl);
        var it = std.mem.splitScalar(u8, block, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r*");
            if (!std.mem.startsWith(u8, line, "@")) continue;
            if (std.mem.startsWith(u8, line, "@param") or std.mem.startsWith(u8, line, "@arg") or
                std.mem.startsWith(u8, line, "@argument"))
            {
                const after_kw = line[std.mem.indexOfScalar(u8, line, ' ') orelse line.len ..];
                const ty = jsdocTagType(after_kw) orelse continue;
                const pname = jsdocParamName(after_kw);
                // Nested tags (`@param {T} obj.prop`) document a property, not
                // the parameter itself — skip so they don't consume a slot.
                if (std.mem.indexOfScalar(u8, pname, '.') != null) continue;
                if (fn_node) |fnn| {
                    const gop = self.jsdoc_params.getOrPut(self.gpa, fnn.toInt()) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    gop.value_ptr.append(self.gpa, .{ .name = pname, .type_str = ty }) catch {};
                }
            } else if (std.mem.startsWith(u8, line, "@returns") or std.mem.startsWith(u8, line, "@return")) {
                const after = if (std.mem.startsWith(u8, line, "@returns")) line["@returns".len..] else line["@return".len..];
                const ty = jsdocTagType(after) orelse continue;
                if (fn_node) |fnn| self.jsdoc_returns.put(self.gpa, fnn.toInt(), ty) catch {};
            } else if (std.mem.startsWith(u8, line, "@type")) {
                const ty = jsdocTagType(line["@type".len..]) orelse continue;
                self.jsdoc_vars.put(self.gpa, decl.toInt(), ty) catch {};
            }
        }
    }

    /// The function node documented by a declaration: a `function` decl is
    /// itself; a `const f = () => …` / `= function(){}` declarator/expr-stmt
    /// unwraps to the inner function expression.
    fn jsdocFunctionOf(self: *Checker, decl: NodeIndex) ?NodeIndex {
        switch (self.ast_ref.nodeTag(decl)) {
            .fn_decl, .async_fn_decl, .generator_fn_decl,
            .async_generator_fn_decl, .ts_declare_function => return decl,
            .var_decl, .let_decl, .const_decl => {
                // First declarator's initializer, if a function/arrow.
                const d = self.ast_ref.nodeData(decl);
                const slice = self.directRange(d.lhs, d.rhs) orelse return null;
                if (slice.len == 0) return null;
                const declr: NodeIndex = @enumFromInt(slice[0]);
                if (self.ast_ref.nodeTag(declr) != .declarator) return null;
                const init_node = self.ast_ref.nodeData(declr).rhs;
                return self.jsdocFunctionOfExpr(init_node);
            },
            .expression_stmt => return self.jsdocFunctionOfExpr(self.ast_ref.nodeData(decl).lhs),
            else => return null,
        }
    }

    fn jsdocFunctionOfExpr(self: *Checker, expr: NodeIndex) ?NodeIndex {
        if (expr == .none) return null;
        return switch (self.ast_ref.nodeTag(expr)) {
            .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
            .arrow_fn, .async_arrow_fn => expr,
            // `foo.x = function(){}` — peel the assignment.
            .assign => self.jsdocFunctionOfExpr(self.ast_ref.nodeData(expr).rhs),
            else => null,
        };
    }

    /// Extract the `{TYPE}` payload immediately after a JSDoc tag keyword,
    /// returning the inner type string (trimmed).  `@param {number} x` → "number".
    fn jsdocTagType(after_tag: []const u8) ?[]const u8 {
        var s = after_tag;
        // Skip whitespace.
        while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
        if (s.len == 0 or s[0] != '{') return null;
        // Balanced-brace scan (object types nest braces).
        var depth: usize = 0;
        var k: usize = 0;
        while (k < s.len) : (k += 1) {
            if (s[k] == '{') depth += 1
            else if (s[k] == '}') {
                depth -= 1;
                if (depth == 0) return std.mem.trim(u8, s[1..k], " \t");
            }
        }
        return null;
    }

    /// Extract the parameter name following the `{TYPE}` of a JSDoc param tag.
    /// `{number} x` → "x"; `{number} [x=1]` → "x"; `{number} obj.p` → "obj.p".
    fn jsdocParamName(after_tag: []const u8) []const u8 {
        var s = after_tag;
        while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
        // Skip the `{TYPE}` payload (balanced braces).
        if (s.len > 0 and s[0] == '{') {
            var depth: usize = 0;
            var k: usize = 0;
            while (k < s.len) : (k += 1) {
                if (s[k] == '{') depth += 1
                else if (s[k] == '}') {
                    depth -= 1;
                    if (depth == 0) { s = s[k + 1 ..]; break; }
                }
            }
        }
        while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
        // Optional `[name=default]` wrapper.
        if (s.len > 0 and s[0] == '[') s = s[1..];
        var end: usize = 0;
        while (end < s.len and ((s[end] >= 'A' and s[end] <= 'Z') or (s[end] >= 'a' and s[end] <= 'z') or
            (s[end] >= '0' and s[end] <= '9') or s[end] == '_' or s[end] == '$' or s[end] == '.')) : (end += 1)
        {}
        return s[0..end];
    }

    /// Parse a JSDoc type string into a TypeId.  Handles primitives, `*`/`?`,
    /// arrays (`T[]` / `Array<T>`), unions (`A | B`), object literals
    /// (`{a: T, b: U}`), nullable (`?T`), and named references.
    fn parseJsdocType(self: *Checker, ty_str: []const u8) TypeId {
        const s = std.mem.trim(u8, ty_str, " \t\r\n");
        if (s.len == 0) return tymod.ID_ANY;
        // Top-level union split (respecting brackets/braces/parens).
        if (self.jsdocSplitUnion(s)) |parts| {
            defer self.gpa.free(parts);
            var buf: [16]TypeId = undefined;
            var n: usize = 0;
            for (parts) |p| {
                if (n >= buf.len) break;
                buf[n] = self.parseJsdocType(p);
                n += 1;
            }
            if (n == 0) return tymod.ID_ANY;
            if (n == 1) return buf[0];
            return self.store.unionOf(buf[0..n]) catch tymod.ID_ANY;
        }
        // Nullable/optional prefixes.
        if (s[0] == '?' or s[0] == '!') return self.parseJsdocType(s[1..]);
        if (s[0] == '*') return tymod.ID_ANY;
        // Optional suffix `=`.
        if (s[s.len - 1] == '=') return self.parseJsdocType(s[0 .. s.len - 1]);
        // Array suffix `T[]`.
        if (s.len >= 2 and s[s.len - 1] == ']' and s[s.len - 2] == '[') {
            const elem = self.parseJsdocType(s[0 .. s.len - 2]);
            return self.store.arrayOf(elem) catch tymod.ID_ANY;
        }
        // Object literal `{a: T, b: U}`.
        if (s[0] == '{' and s[s.len - 1] == '}') {
            return self.parseJsdocObjectType(s[1 .. s.len - 1]);
        }
        // Parenthesized.
        if (s[0] == '(' and s[s.len - 1] == ')') return self.parseJsdocType(s[1 .. s.len - 1]);
        // `Array<T>` / `Promise<T>` / generic.
        if (std.mem.indexOfScalar(u8, s, '<')) |lt| {
            if (s[s.len - 1] == '>') {
                const base = s[0..lt];
                const inner = s[lt + 1 .. s.len - 1];
                if (std.mem.eql(u8, base, "Array")) {
                    return self.store.arrayOf(self.parseJsdocType(inner)) catch tymod.ID_ANY;
                }
                // Other generics → named type_ref with one arg (best effort).
                const arg = self.parseJsdocType(inner);
                return self.store.typeRef(base, &.{arg}) catch tymod.ID_ANY;
            }
        }
        // Primitives & keywords.
        if (std.mem.eql(u8, s, "number")) return tymod.ID_NUMBER;
        if (std.mem.eql(u8, s, "string")) return tymod.ID_STRING;
        if (std.mem.eql(u8, s, "boolean")) return tymod.ID_BOOLEAN;
        if (std.mem.eql(u8, s, "bigint")) return tymod.ID_BIGINT;
        if (std.mem.eql(u8, s, "symbol")) return tymod.ID_SYMBOL;
        if (std.mem.eql(u8, s, "undefined")) return tymod.ID_UNDEFINED;
        if (std.mem.eql(u8, s, "null")) return tymod.ID_NULL;
        if (std.mem.eql(u8, s, "void")) return tymod.ID_VOID;
        if (std.mem.eql(u8, s, "any") or std.mem.eql(u8, s, "*")) return tymod.ID_ANY;
        if (std.mem.eql(u8, s, "unknown")) return tymod.ID_UNKNOWN;
        if (std.mem.eql(u8, s, "never")) return tymod.ID_NEVER;
        if (std.mem.eql(u8, s, "object")) return tymod.ID_OBJECT_KW;
        // String/number literal types.
        if (s[0] == '"' or s[0] == '\'') {
            if (s.len >= 2 and s[s.len - 1] == s[0]) {
                return self.store.add(.{ .kind = .string_literal, .literal_value = .{ .string = s[1 .. s.len - 1] } }) catch tymod.ID_STRING;
            }
        }
        // A bare identifier (possibly dotted) → named type_ref, but only if it
        // looks like a type name; otherwise `any`.
        if (jsdocLooksLikeName(s)) return self.store.typeRef(s, &.{}) catch tymod.ID_ANY;
        return tymod.ID_ANY;
    }

    /// Parse the body of a JSDoc object type `a: T, b: U` into an object_t.
    fn parseJsdocObjectType(self: *Checker, body: []const u8) TypeId {
        var props_buf: [32]tymod.ObjectProp = undefined;
        var n: usize = 0;
        var start: usize = 0;
        var depth: usize = 0;
        var k: usize = 0;
        // Split on top-level commas.
        while (k <= body.len) : (k += 1) {
            const at_end = k == body.len;
            const c = if (at_end) ',' else body[k];
            if (!at_end and (c == '{' or c == '<' or c == '(' or c == '[')) depth += 1
            else if (!at_end and (c == '}' or c == '>' or c == ')' or c == ']')) {
                if (depth > 0) depth -= 1;
            } else if (c == ',' and depth == 0) {
                const field = std.mem.trim(u8, body[start..k], " \t\r\n");
                if (field.len > 0 and n < props_buf.len) {
                    if (self.parseJsdocField(field)) |p| {
                        props_buf[n] = p;
                        n += 1;
                    }
                }
                start = k + 1;
            }
        }
        if (n == 0) return tymod.ID_OBJECT_KW;
        const list = self.store.appendObjectProps(props_buf[0..n]) catch return tymod.ID_ANY;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch tymod.ID_ANY;
    }

    fn parseJsdocField(self: *Checker, field: []const u8) ?tymod.ObjectProp {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse return null;
        var key = std.mem.trim(u8, field[0..colon], " \t");
        var optional = false;
        if (key.len > 0 and key[key.len - 1] == '?') {
            optional = true;
            key = std.mem.trim(u8, key[0 .. key.len - 1], " \t");
        }
        if (key.len == 0) return null;
        var vty = self.parseJsdocType(field[colon + 1 ..]);
        if (optional and !self.typeContainsUndefined(vty)) {
            vty = self.store.unionOf(&.{ vty, tymod.ID_UNDEFINED }) catch vty;
        }
        return .{ .name = key, .type_id = vty, .optional = optional };
    }

    /// Split a JSDoc type on top-level `|` (union).  Returns null when there's
    /// no top-level union.  Caller frees the returned slice.
    fn jsdocSplitUnion(self: *Checker, s: []const u8) ?[][]const u8 {
        var parts = std.ArrayListUnmanaged([]const u8).empty;
        var depth: usize = 0;
        var start: usize = 0;
        var k: usize = 0;
        var found = false;
        while (k < s.len) : (k += 1) {
            const c = s[k];
            if (c == '{' or c == '<' or c == '(' or c == '[') depth += 1
            else if (c == '}' or c == '>' or c == ')' or c == ']') {
                if (depth > 0) depth -= 1;
            } else if (c == '|' and depth == 0) {
                found = true;
                parts.append(self.gpa, std.mem.trim(u8, s[start..k], " \t")) catch {};
                start = k + 1;
            }
        }
        if (!found) {
            parts.deinit(self.gpa);
            return null;
        }
        parts.append(self.gpa, std.mem.trim(u8, s[start..], " \t")) catch {};
        return parts.toOwnedSlice(self.gpa) catch null;
    }

    /// True when a JSDoc type string is a plausible type name (identifier,
    /// possibly dotted/`$`/`_`), so it should become a named type_ref rather
    /// than `any`.
    fn jsdocLooksLikeName(s: []const u8) bool {
        if (s.len == 0) return false;
        const c0 = s[0];
        if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_' or c0 == '$')) return false;
        for (s) |c| {
            if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '_' or c == '$' or c == '.')) return false;
        }
        return true;
    }

    /// JSDoc `@returns {T}` type for the function enclosing `body`, parsed to a
    /// TypeId.  Returns null when not a JS file, no body, or no `@returns`.
    fn jsdocReturnTypeForBody(self: *Checker, body: NodeIndex) ?TypeId {
        if (body == .none) return null;
        if (!self.checker_opts.is_js_file) return null;
        if (!self.jsdoc_built) self.buildJsdoc();
        if (self.jsdoc_returns.count() == 0) return null;
        // The body's parent chain reaches the enclosing function node.
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var p = if (body.toInt() < parents.len) parents[body.toInt()] else NONE;
        var depth: u8 = 0;
        while (p != NONE and depth < 8) : (depth += 1) {
            const pn: NodeIndex = @enumFromInt(p);
            switch (self.ast_ref.nodeTag(pn)) {
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                .arrow_fn, .async_arrow_fn, .ts_declare_function => {
                    if (self.jsdoc_returns.get(pn.toInt())) |ts| return self.parseJsdocType(ts);
                    return null;
                },
                else => {},
            }
            p = if (pn.toInt() < parents.len) parents[pn.toInt()] else NONE;
        }
        return null;
    }

    /// JSDoc `@param` type string for a parameter — matched by name when the
    /// param has one, else by ordinal position.
    fn jsdocParamType(self: *Checker, fn_node: NodeIndex, ordinal: usize, param_name: []const u8) ?[]const u8 {
        if (!self.jsdoc_built) self.buildJsdoc();
        const lst = self.jsdoc_params.get(fn_node.toInt()) orelse return null;
        if (param_name.len > 0) {
            for (lst.items) |jp| {
                if (std.mem.eql(u8, jp.name, param_name)) return jp.type_str;
            }
        }
        // Fall back to ordinal (destructured params have no name to match).
        if (ordinal < lst.items.len) return lst.items[ordinal].type_str;
        return null;
    }

    /// Type of a parameter binding from a JSDoc `@param` tag, navigating the
    /// pattern path for destructured params (`@param {{a:number}} o` →
    /// `function f({a})` → a : number).  Returns null when no JSDoc applies.
    fn jsdocParamBindingType(self: *Checker, binding: NodeIndex) ?TypeId {
        if (!self.jsdoc_built) self.buildJsdoc();
        if (self.jsdoc_params.count() == 0) return null;
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const PathStep = union(enum) { key: []const u8, index: usize };
        var path: [16]PathStep = undefined;
        var npath: usize = 0;

        var node = binding;
        while (true) {
            const nidx = node.toInt();
            if (nidx >= parents.len) return null;
            const pidx = parents[nidx];
            if (pidx == NONE) return null;
            const parent: NodeIndex = @enumFromInt(pidx);
            switch (self.ast_ref.nodeTag(parent)) {
                .property => {
                    const pd = self.ast_ref.nodeData(parent);
                    const is_value = pd.rhs == node or
                        (pd.rhs != .none and self.ast_ref.nodeTag(pd.rhs) == .assignment_pattern and
                            self.ast_ref.nodeData(pd.rhs).lhs == node);
                    if (!is_value) return null;
                    if (npath >= path.len) return null;
                    path[npath] = .{ .key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pd.lhs)) };
                    npath += 1;
                    node = parent;
                },
                .shorthand_property => {
                    const pd = self.ast_ref.nodeData(parent);
                    var keyn = pd.lhs;
                    if (keyn != .none and self.ast_ref.nodeTag(keyn) == .assignment_pattern)
                        keyn = self.ast_ref.nodeData(keyn).lhs;
                    if (npath >= path.len) return null;
                    path[npath] = .{ .key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(keyn)) };
                    npath += 1;
                    node = parent;
                },
                .assignment_pattern, .object_pattern => node = parent,
                .array_pattern => {
                    const d = self.ast_ref.nodeData(parent);
                    const slice = self.directRange(d.lhs, d.rhs) orelse return null;
                    var idx: usize = 0;
                    var found = false;
                    for (slice) |raw| {
                        if (@as(NodeIndex, @enumFromInt(raw)) == node) { found = true; break; }
                        idx += 1;
                    }
                    if (!found) return null;
                    if (npath >= path.len) return null;
                    path[npath] = .{ .index = idx };
                    npath += 1;
                    node = parent;
                },
                else => {
                    // `parent` is the function; `node` is the top-level param.
                    const ord = self.paramOrdinalInFn(parent, node) orelse return null;
                    // The param's own name (empty for a destructuring pattern).
                    const pname: []const u8 = if (self.ast_ref.nodeTag(node) == .identifier)
                        self.ast_ref.tokenText(self.ast_ref.nodeMainToken(node))
                    else
                        &.{};
                    const ty_str = self.jsdocParamType(parent, ord, pname) orelse return null;
                    var ty = self.parseJsdocType(ty_str);
                    var k: usize = npath;
                    while (k > 0) {
                        k -= 1;
                        ty = switch (path[k]) {
                            .key => |key| self.memberOnApparentType(ty, key, node),
                            .index => |idx| self.tupleOrArrayElement(ty, idx) orelse return null,
                        };
                        if (ty.eq(tymod.ID_UNKNOWN) or ty.eq(tymod.ID_ANY)) return ty;
                    }
                    return ty;
                },
            }
        }
    }

    /// Ordinal of `param_node` in a function-like node's parameter list.
    fn paramOrdinalInFn(self: *Checker, fn_node: NodeIndex, param_node: NodeIndex) ?usize {
        const data = self.ast_ref.nodeData(fn_node);
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        var ps: u32 = 0;
        var pe: u32 = 0;
        switch (self.ast_ref.nodeTag(fn_node)) {
            .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
            .ts_declare_function => {
                if (data.lhs == .none) return null;
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
                ps = fd.params;
                pe = fd.params_end;
            },
            .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr => {
                if (data.lhs == .none) return null;
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
                ps = fd.params;
                pe = fd.params_end;
            },
            .arrow_fn, .async_arrow_fn => {
                if (data.lhs == .none) return null;
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
                ps = fd.params;
                pe = fd.params_end;
            },
            else => return null,
        }
        if (ps > pe or pe > ext_len) return null;
        var ord: usize = 0;
        for (self.ast_ref.extra_data[ps..pe]) |raw| {
            if (@as(NodeIndex, @enumFromInt(raw)) == param_node) return ord;
            ord += 1;
        }
        return null;
    }

    /// Build the pattern→annotation reverse index (lazy, once).  A pattern's
    /// `: T` annotation is a `ts_type_annotation` child node whose parent is the
    /// pattern but which isn't reachable from the pattern's prop/element range.
    fn buildPatternAnnotations(self: *Checker) void {
        self.pattern_annotations_built = true;
        const parents = self.semantic.parent_indices;
        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var i: u32 = 1;
        while (i < total) : (i += 1) {
            const ni: NodeIndex = @enumFromInt(i);
            if (self.ast_ref.nodeTag(ni) != .ts_type_annotation) continue;
            if (i >= parents.len) continue;
            const pidx = parents[i];
            if (pidx == @intFromEnum(NodeIndex.none)) continue;
            const ptag = self.ast_ref.nodeTag(@enumFromInt(pidx));
            if (ptag == .object_pattern or ptag == .array_pattern) {
                self.pattern_annotations.put(self.gpa, pidx, ni) catch {};
            }
        }
    }

    /// A destructured *parameter* binding (`function f({ a: x }: T)`) takes its
    /// type from the parameter's type annotation, navigated by the pattern path
    /// from the binding up to the annotated pattern.  Returns null when the
    /// binding isn't a parameter destructuring or its type can't be resolved.
    fn destructuredParamBindingType(self: *Checker, binding: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const PathStep = union(enum) { key: []const u8, index: usize, rest_obj, rest_arr };
        var path: [16]PathStep = undefined;
        var npath: usize = 0;

        var node = binding;
        while (true) {
            const nidx = node.toInt();
            if (nidx >= parents.len) return null;
            const pidx = parents[nidx];
            if (pidx == NONE) return null;
            const parent: NodeIndex = @enumFromInt(pidx);
            switch (self.ast_ref.nodeTag(parent)) {
                .property => {
                    const pd = self.ast_ref.nodeData(parent);
                    // Only the value side (rhs) is a binding; the key (lhs) is a
                    // property reference that tsc types `any`.  `node` may be the
                    // rhs directly or an assignment_pattern wrapping it.
                    const is_value = pd.rhs == node or
                        (pd.rhs != .none and self.ast_ref.nodeTag(pd.rhs) == .assignment_pattern and
                            self.ast_ref.nodeData(pd.rhs).lhs == node);
                    if (!is_value) return null;
                    if (npath >= path.len) return null;
                    path[npath] = .{ .key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pd.lhs)) };
                    npath += 1;
                    node = parent;
                },
                .shorthand_property => {
                    const pd = self.ast_ref.nodeData(parent);
                    var keyn = pd.lhs;
                    if (keyn != .none and self.ast_ref.nodeTag(keyn) == .assignment_pattern)
                        keyn = self.ast_ref.nodeData(keyn).lhs;
                    if (npath >= path.len) return null;
                    path[npath] = .{ .key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(keyn)) };
                    npath += 1;
                    node = parent;
                },
                .assignment_pattern => {
                    // Default value wrapper inside a pattern — skip.
                    node = parent;
                },
                .array_pattern => {
                    // Find `node`'s element index within the array pattern.
                    const d = self.ast_ref.nodeData(parent);
                    const slice = self.directRange(d.lhs, d.rhs) orelse return null;
                    var idx: usize = 0;
                    var found = false;
                    for (slice) |raw| {
                        const el: NodeIndex = @enumFromInt(raw);
                        if (el == node) { found = true; break; }
                        idx += 1;
                    }
                    if (!found) return null;
                    if (npath >= path.len) return null;
                    path[npath] = .{ .index = idx };
                    npath += 1;
                    node = parent;
                },
                .object_pattern => {
                    node = parent; // descend handled via the property step
                },
                else => {
                    // `parent` is the enclosing declaration; `node` is the
                    // top-level pattern.  Only proceed for function parameters.
                    if (!self.isFunctionParamNode(node)) return null;
                    const ptag = self.ast_ref.nodeTag(node);
                    if (ptag != .object_pattern and ptag != .array_pattern) return null;
                    if (!self.pattern_annotations_built) self.buildPatternAnnotations();
                    const ann = self.pattern_annotations.get(node.toInt()) orelse return null;
                    const ann_ty_node = self.ast_ref.nodeData(ann).lhs;
                    if (ann_ty_node == .none) return null;
                    var ty = self.resolveTypeNode(ann_ty_node);
                    // Navigate the path from outermost (last pushed) to innermost.
                    var k: usize = npath;
                    while (k > 0) {
                        k -= 1;
                        ty = switch (path[k]) {
                            .key => |key| self.memberOnApparentType(ty, key, node),
                            .index => |idx| self.tupleOrArrayElement(ty, idx) orelse return null,
                            .rest_obj, .rest_arr => return null,
                        };
                        if (ty.eq(tymod.ID_UNKNOWN) or ty.eq(tymod.ID_ANY)) return ty;
                    }
                    return ty;
                },
            }
        }
    }

    /// Element type of a tuple at `idx`, or an array's element type.
    fn tupleOrArrayElement(self: *Checker, id: TypeId, idx: usize) ?TypeId {
        const t = self.store.get(id);
        switch (t.kind) {
            .tuple_t => {
                const elems = self.store.idsOf(t.list_data);
                if (idx < elems.len) return self.peelRestElem(elems[idx]);
                return null;
            },
            .array_t, .readonly_array_t => {
                const elems = self.store.idsOf(t.list_data);
                if (elems.len > 0) return elems[0];
                return null;
            },
            else => return null,
        }
    }

    fn inferTypeFromDestructuringPattern(self: *Checker, binding: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const bidx = binding.toInt();
        if (bidx >= parents.len) return null;
        const NONE: u32 = @intFromEnum(NodeIndex.none);

        // Walk up the parent chain looking for a declarator or assignment_pattern
        // that has an RHS. Track the pattern node we came from to match against the LHS.
        var cur: u32 = parents[bidx];
        if (cur == NONE) return null;

        var pattern_node = binding;
        var depth: u32 = 0;
        while (cur != NONE and depth < 32) : ({ pattern_node = @enumFromInt(cur); cur = parents[cur]; depth += 1; }) {
            const tag = self.ast_ref.nodeTag(@enumFromInt(cur));
            switch (tag) {
                .declarator => {
                    const data = self.ast_ref.nodeData(@enumFromInt(cur));
                    // If the pattern we came from is the LHS of this declarator
                    // and there's an RHS, infer the binding's type from the RHS.
                    if (data.lhs == pattern_node and data.rhs != .none) {
                        const rhs_type = self.typeOf(data.rhs);
                        const rhs_t = self.store.get(rhs_type);

                        // Array destructuring: `const [x, y] = tuple_or_array`
                        if (rhs_t.kind == .tuple_t or rhs_t.kind == .array_t or rhs_t.kind == .readonly_array_t) {
                            if (self.findBindingIndexInPattern(binding, @enumFromInt(cur))) |idx| {
                                var elem_ty: TypeId = tymod.ID_ANY;
                                if (rhs_t.kind == .tuple_t) {
                                    const elems = self.store.idsOf(rhs_t.list_data);
                                    if (idx < elems.len) elem_ty = self.peelRestElem(elems[idx]);
                                } else {
                                    const elem_list = self.store.idsOf(rhs_t.list_data);
                                    if (elem_list.len > 0) elem_ty = elem_list[0];
                                }
                                // Widen literal types: TypeScript widens literals in destructuring
                                // unless the source has `as const`. This is the default behavior.
                                return switch (self.store.get(elem_ty).kind) {
                                    .number_literal => tymod.ID_NUMBER,
                                    .string_literal => tymod.ID_STRING,
                                    .boolean_literal => tymod.ID_BOOLEAN,
                                    .bigint_literal => tymod.ID_BIGINT,
                                    else => elem_ty,
                                };
                            }
                        }
                        // Object destructuring: `const { j } = obj`
                        if (rhs_t.kind == .object_t) {
                            if (self.findBindingPropertyName(binding, pattern_node)) |key| {
                                if (self.propertyTypeOfTypeId(rhs_type, key)) |prop_ty| {
                                    // Widen literal types for object destructuring too
                                    return switch (self.store.get(prop_ty).kind) {
                                        .number_literal => tymod.ID_NUMBER,
                                        .string_literal => tymod.ID_STRING,
                                        .boolean_literal => tymod.ID_BOOLEAN,
                                        .bigint_literal => tymod.ID_BIGINT,
                                        else => prop_ty,
                                    };
                                }
                            }
                        }
                        return null;
                    }
                    return null;
                },
                .assignment_pattern => {
                    // Function parameter with default: `[x] = default`.
                    const data = self.ast_ref.nodeData(@enumFromInt(cur));
                    if (data.lhs == pattern_node and data.rhs != .none) {
                        // Return the type of the default value.
                        return self.typeOf(data.rhs);
                    }
                    return null;
                },
                else => {
                    // Keep walking up - we might have nested patterns
                    // Don't return null yet, continue searching
                },
            }
        }
        return null;
    }

    /// Find the index of a binding within a declarator's LHS pattern.
    /// For `[x, y, z] = rhs`, returns 0 for x, 1 for y, 2 for z.
    /// Uses a simple recursive scan of the pattern structure.
    fn findBindingIndexInPattern(self: *Checker, binding: NodeIndex, declarator: NodeIndex) ?usize {
        const data = self.ast_ref.nodeData(declarator);
        if (data.lhs == .none) return null;
        // Start scanning from the declarator's LHS pattern
        return self.findBindingIndexInPatternNode(binding, data.lhs, 0);
    }

    /// Find binding's 0-based index within an array_pattern (flat, one level).
    /// For `[x, y, z]`, returns 0/1/2 for the respective bindings.
    fn findBindingIndexInPatternNode(self: *Checker, binding: NodeIndex, pattern: NodeIndex, index_start: usize) ?usize {
        if (binding == pattern) return index_start;

        const tag = self.ast_ref.nodeTag(pattern);
        switch (tag) {
            .assignment_pattern => {
                // `elem = default` — the real binding is lhs (unwrap one level)
                const d = self.ast_ref.nodeData(pattern);
                if (d.lhs == binding) return index_start;
                return null;
            },
            .array_pattern => {
                // array_pattern stores lhs=start, rhs=end (direct range into extra_data)
                const d = self.ast_ref.nodeData(pattern);
                const slice = self.directRange(d.lhs, d.rhs) orelse return null;
                for (slice, 0..) |raw, i| {
                    const elem: NodeIndex = @enumFromInt(raw);
                    if (elem == .none) continue; // elision hole
                    if (elem == binding) return index_start + i;
                    // Unwrap assignment_pattern (default values): `[x = 0]`
                    const etag = self.ast_ref.nodeTag(elem);
                    if (etag == .assignment_pattern) {
                        const ed = self.ast_ref.nodeData(elem);
                        if (ed.lhs == binding) return index_start + i;
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Find the property key name for a binding inside an object_pattern.
    /// For `{ j }` → "j"; for `{ j: k }` and binding=k → "j".
    fn findBindingPropertyName(self: *Checker, binding: NodeIndex, pattern: NodeIndex) ?[]const u8 {
        if (self.ast_ref.nodeTag(pattern) != .object_pattern) return null;
        // object_pattern stores lhs=start, rhs=end (direct range into extra_data)
        const d = self.ast_ref.nodeData(pattern);
        const slice = self.directRange(d.lhs, d.rhs) orelse return null;
        for (slice) |raw| {
            const prop: NodeIndex = @enumFromInt(raw);
            if (prop == .none) continue;
            const ptag = self.ast_ref.nodeTag(prop);
            switch (ptag) {
                .shorthand_property => {
                    // `{ j }` — lhs is identifier (= key = value)
                    const pd = self.ast_ref.nodeData(prop);
                    if (pd.lhs == binding) {
                        return self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pd.lhs));
                    }
                    // Shorthand with default `{ j = default }` — lhs is assignment_pattern
                    if (pd.lhs != .none and self.ast_ref.nodeTag(pd.lhs) == .assignment_pattern) {
                        const ad = self.ast_ref.nodeData(pd.lhs);
                        if (ad.lhs == binding) {
                            return self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ad.lhs));
                        }
                    }
                },
                .property => {
                    // `{ j: k }` — lhs is key node, rhs is value/binding
                    const pd = self.ast_ref.nodeData(prop);
                    if (pd.rhs == binding) {
                        return self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pd.lhs));
                    }
                    // rhs might be assignment_pattern wrapping the binding
                    if (pd.rhs != .none and self.ast_ref.nodeTag(pd.rhs) == .assignment_pattern) {
                        const ad = self.ast_ref.nodeData(pd.rhs);
                        if (ad.lhs == binding) {
                            return self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pd.lhs));
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// If `binding` is the first parameter of an arrow/function-expression
    /// callback passed as the first argument to a recognised array
    /// predicate method (`.some`/`.every`/`.filter`/`.find`/...), return
    /// the array's element type.  Otherwise null.
    fn contextualArrayPredicateParamType(self: *Checker, binding: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const bidx = binding.toInt();
        if (bidx >= parents.len) return null;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        // Walk up: identifier → arrow_fn/fn_expr (the callback).
        var cur = parents[bidx];
        if (cur == NONE) return null;
        // Skip through patterns / ts_parameter_property / rest_element.
        var fn_node: NodeIndex = .none;
        var first_param_idx: u32 = 0;
        var depth: u32 = 0;
        while (cur != NONE and depth < 8) : ({ cur = parents[cur]; depth += 1; }) {
            const t = self.ast_ref.nodeTag(@enumFromInt(cur));
            switch (t) {
                .arrow_fn, .async_arrow_fn,
                .fn_expr, .async_fn_expr,
                .generator_fn_expr, .async_generator_fn_expr,
                => { fn_node = @enumFromInt(cur); break; },
                else => {},
            }
        }
        if (fn_node == .none) return null;
        // The callback must be the first param of the fn — only first
        // params get the element type.
        const fn_idx = fn_node.toInt();
        const fn_tag = self.ast_ref.nodeTag(fn_node);
        var pstart: u32 = 0;
        var pend: u32 = 0;
        switch (fn_tag) {
            .arrow_fn, .async_arrow_fn => {
                const fd_d = self.ast_ref.nodeData(fn_node);
                if (fd_d.lhs == .none) return null;
                const ad = self.ast_ref.extraData(ast.ArrowData, @intFromEnum(fd_d.lhs));
                pstart = ad.params_start; pend = ad.params_end;
            },
            else => {
                const fd_d = self.ast_ref.nodeData(fn_node);
                if (fd_d.lhs == .none) return null;
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(fd_d.lhs));
                pstart = fd.params; pend = fd.params_end;
            },
        }
        if (pend <= pstart or pend > self.ast_ref.extra_data.len) return null;
        const params = self.ast_ref.extra_data[pstart..pend];
        // Binding must be (the un-annotated id reachable from) the first
        // param.  Walk the first param's children — direct identifier
        // wins, or peel patterns.
        first_param_idx = params[0];
        var p_node: NodeIndex = @enumFromInt(first_param_idx);
        if (self.ast_ref.nodeTag(p_node) == .ts_parameter_property) p_node = self.ast_ref.nodeData(p_node).lhs;
        if (self.ast_ref.nodeTag(p_node) == .assignment_pattern) p_node = self.ast_ref.nodeData(p_node).lhs;
        if (self.ast_ref.nodeTag(p_node) == .rest_element) p_node = self.ast_ref.nodeData(p_node).lhs;
        if (p_node != binding) return null;
        _ = fn_idx;
        // The fn must be the first argument of a call to an array
        // predicate method.
        const fn_parent = parents[fn_node.toInt()];
        if (fn_parent == NONE) return null;
        const call_node: NodeIndex = @enumFromInt(fn_parent);
        if (self.ast_ref.nodeTag(call_node) != .call_expr) return null;
        const cd = self.ast_ref.nodeData(call_node);
        // Callee must be `<arrLike>.<predicate>`.
        var callee = cd.lhs;
        while (self.ast_ref.nodeTag(callee) == .grouping_expr) callee = self.ast_ref.nodeData(callee).lhs;
        const callee_tag = self.ast_ref.nodeTag(callee);
        if (callee_tag != .member_expr and callee_tag != .optional_member_expr) return null;
        const md = self.ast_ref.nodeData(callee);
        if (md.rhs == .none) return null;
        const method = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
        if (!isArrayPredicateMethodName(method)) return null;
        // First argument of the call must be the fn we found.
        if (cd.rhs == .none) return null;
        const sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(cd.rhs));
        if (sr.start >= sr.end or sr.end > self.ast_ref.extra_data.len) return null;
        const arg0_idx = self.ast_ref.extra_data[sr.start];
        if (arg0_idx != fn_node.toInt()) return null;
        // Receiver's array element type.
        const recv_ty = self.typeOf(md.lhs);
        const elem = self.arrayMethodElementTypeOf(recv_ty) orelse return null;
        return elem;
    }

    /// Generic contextual typing for arrow/fn-expr callbacks.
    /// `bar(x => ...)` where `bar(cb: (arg: Foo) => void)`: the arrow's
    /// `x` should get type `Foo` from the callee's signature.
    fn contextualCallbackParamType(self: *Checker, binding: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        const bidx = binding.toInt();
        if (bidx >= parents.len) return null;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        // Walk up: binding → arrow_fn / fn_expr.
        var cur = parents[bidx];
        if (cur == NONE) return null;
        var fn_node: NodeIndex = .none;
        var depth: u32 = 0;
        while (cur != NONE and depth < 8) : ({ cur = parents[cur]; depth += 1; }) {
            const t = self.ast_ref.nodeTag(@enumFromInt(cur));
            switch (t) {
                .arrow_fn, .async_arrow_fn,
                .fn_expr, .async_fn_expr,
                => { fn_node = @enumFromInt(cur); break; },
                else => {},
            }
        }
        if (fn_node == .none) return null;
        // The binding must be one of fn_node's parameters; find which slot.
        const fn_tag = self.ast_ref.nodeTag(fn_node);
        var pstart: u32 = 0;
        var pend: u32 = 0;
        switch (fn_tag) {
            .arrow_fn, .async_arrow_fn => {
                const fd_d = self.ast_ref.nodeData(fn_node);
                if (fd_d.lhs == .none) return null;
                const ad = self.ast_ref.extraData(ast.ArrowData, @intFromEnum(fd_d.lhs));
                pstart = ad.params_start; pend = ad.params_end;
            },
            else => {
                const fd_d = self.ast_ref.nodeData(fn_node);
                if (fd_d.lhs == .none) return null;
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(fd_d.lhs));
                pstart = fd.params; pend = fd.params_end;
            },
        }
        if (pend <= pstart or pend > self.ast_ref.extra_data.len) return null;
        const params = self.ast_ref.extra_data[pstart..pend];
        var param_slot: i32 = -1;
        for (params, 0..) |raw, idx| {
            var p_node: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(p_node) == .ts_parameter_property) p_node = self.ast_ref.nodeData(p_node).lhs;
            if (self.ast_ref.nodeTag(p_node) == .assignment_pattern) p_node = self.ast_ref.nodeData(p_node).lhs;
            if (self.ast_ref.nodeTag(p_node) == .rest_element) p_node = self.ast_ref.nodeData(p_node).lhs;
            if (p_node == binding) { param_slot = @intCast(idx); break; }
        }
        if (param_slot < 0) return null;
        // The fn must be an argument to a call.
        const fn_parent_raw = parents[fn_node.toInt()];
        if (fn_parent_raw == NONE) return null;
        const call_node: NodeIndex = @enumFromInt(fn_parent_raw);
        if (self.ast_ref.nodeTag(call_node) != .call_expr) return null;
        const cd = self.ast_ref.nodeData(call_node);
        if (cd.rhs == .none) return null;
        const sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(cd.rhs));
        if (sr.start >= sr.end or sr.end > self.ast_ref.extra_data.len) return null;
        // Find which arg slot our fn is.
        const args = self.ast_ref.extra_data[sr.start..sr.end];
        var arg_slot: i32 = -1;
        for (args, 0..) |raw, idx| {
            if (raw == fn_node.toInt()) { arg_slot = @intCast(idx); break; }
        }
        if (arg_slot < 0) return null;
        // Peel ts_instantiation_expr from callee (`foo<T>(cb)` pattern) and
        // capture explicit type arg nodes for substitution below.
        var actual_callee = cd.lhs;
        var explicit_type_arg_nodes: []const u32 = &.{};
        if (self.ast_ref.nodeTag(actual_callee) == .ts_instantiation_expr) {
            const inst_d = self.ast_ref.nodeData(actual_callee);
            actual_callee = inst_d.lhs;
            if (inst_d.rhs != .none) {
                const ta_sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(inst_d.rhs));
                if (ta_sr.start < ta_sr.end and ta_sr.end <= self.ast_ref.extra_data.len)
                    explicit_type_arg_nodes = self.ast_ref.extra_data[ta_sr.start..ta_sr.end];
            }
        }
        // Resolve callee's function type → arg_slot-th param → its
        // signature's param_slot-th param type.
        const callee_ty = self.typeOf(actual_callee);
        const ct = self.store.get(callee_ty);
        if (ct.kind != .function_t) return null;
        const sigs = self.store.signaturesOf(ct.signatures);
        if (sigs.len == 0) return null;
        const sig = sigs[0];
        const params_t = self.store.signatureParamsOf(sig);
        if (@as(usize, @intCast(arg_slot)) >= params_t.len) return null;
        const cb_ty = params_t[@intCast(arg_slot)];
        // cb_ty should be a function type — take its param_slot-th param.
        const cb_t = self.store.get(cb_ty);
        if (cb_t.kind != .function_t) return null;
        const cb_sigs = self.store.signaturesOf(cb_t.signatures);
        if (cb_sigs.len == 0) return null;
        const cb_sig = cb_sigs[0];
        const cb_params = self.store.signatureParamsOf(cb_sig);
        if (@as(usize, @intCast(param_slot)) >= cb_params.len) return null;
        var result = cb_params[@intCast(param_slot)];
        // When we have explicit type args (e.g. `foo<string[]>(cb)`), substitute
        // them into the result if it is an unresolved type_ref.
        if (explicit_type_arg_nodes.len > 0 and self.store.get(result).kind == .type_ref) {
            if (self.findCalleeFnDecl(actual_callee)) |fn_decl| {
                const fd_lhs = self.ast_ref.nodeData(fn_decl).lhs;
                const fn_fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(fd_lhs));
                if (fn_fd.type_params < fn_fd.type_params_end and
                    fn_fd.type_params_end <= self.ast_ref.extra_data.len)
                {
                    const tp_nodes = self.ast_ref.extra_data[fn_fd.type_params..fn_fd.type_params_end];
                    var names_buf: [4][]const u8 = undefined;
                    var vals_buf: [4]TypeId = undefined;
                    var count: usize = 0;
                    for (tp_nodes, 0..) |raw, ti| {
                        if (count >= 4 or ti >= explicit_type_arg_nodes.len) break;
                        const tp: NodeIndex = @enumFromInt(raw);
                        if (self.ast_ref.nodeTag(tp) != .ts_type_parameter) continue;
                        names_buf[count] = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp));
                        const ta_node: NodeIndex = @enumFromInt(explicit_type_arg_nodes[ti]);
                        vals_buf[count] = self.resolveTypeNode(ta_node);
                        count += 1;
                    }
                    if (count > 0) result = self.substituteTypeId(result, names_buf[0..count], vals_buf[0..count]);
                }
            }
        }
        return result;
    }

    fn isArrayPredicateMethodName(name: []const u8) bool {
        return std.mem.eql(u8, name, "filter") or
            std.mem.eql(u8, name, "find") or
            std.mem.eql(u8, name, "findIndex") or
            std.mem.eql(u8, name, "findLast") or
            std.mem.eql(u8, name, "findLastIndex") or
            std.mem.eql(u8, name, "some") or
            std.mem.eql(u8, name, "every") or
            std.mem.eql(u8, name, "map") or
            std.mem.eql(u8, name, "forEach") or
            std.mem.eql(u8, name, "flatMap");
    }

    fn elementTypeOf(self: *Checker, id: TypeId) ?TypeId {
        const t = self.store.get(id);
        switch (t.kind) {
            .array_t, .readonly_array_t => {
                const elems = self.store.idsOf(t.list_data);
                if (elems.len == 0) return null;
                return elems[0];
            },
            .tuple_t => {
                const elems = self.store.idsOf(t.list_data);
                if (elems.len == 0) return null;
                if (elems.len == 1) return elems[0];
                return self.store.unionOf(elems) catch elems[0];
            },
            .union_t => {
                var buf: [16]TypeId = undefined;
                var n: usize = 0;
                for (self.store.idsOf(t.list_data)) |m| {
                    const e = self.elementTypeOf(m) orelse return null;
                    if (n >= buf.len) return null;
                    buf[n] = e;
                    n += 1;
                }
                if (n == 0) return null;
                if (n == 1) return buf[0];
                return self.store.unionOf(buf[0..n]) catch null;
            },
            else => return null,
        }
    }

    /// If `ret_node` is a ts_type_reference to a type-parameter `T`
    /// whose constraint is a literal type (`true`, `"foo"`, `42`, `0n`),
    /// return that literal TypeId.  Otherwise return `fallback` (the
    /// already-resolved type, typically a type_ref).
    fn foldTypeParamLiteralConstraint(self: *Checker, ret_node: NodeIndex, fallback: TypeId) TypeId {
        var n = ret_node;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type)
            n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .ts_type_reference) return fallback;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
        const tp = self.findTypeParameterDecl(n, name) orelse return fallback;
        const constraint = self.ast_ref.nodeData(tp).lhs;
        if (constraint == .none) return fallback;
        const resolved = self.resolveTypeNode(constraint);
        const rt = self.store.get(resolved);
        return switch (rt.kind) {
            .string_literal, .number_literal, .bigint_literal,
            .boolean_literal, .null_t, .undefined_t, .never,
            => resolved,
            else => fallback,
        };
    }

    /// Compute the effective element type for array method calls, widening
    /// tuple element literals to their base types. When a tuple is used
    /// via array methods (map, filter, etc.), its elements are accessed
    /// via the callback parameter, which should be the widened type, not
    /// the literal tuple element types.
    fn arrayMethodElementTypeOf(self: *Checker, id: TypeId) ?TypeId {
        const t = self.store.get(id);
        switch (t.kind) {
            .array_t, .readonly_array_t => {
                const elems = self.store.idsOf(t.list_data);
                if (elems.len == 0) return null;
                return elems[0];
            },
            .tuple_t => {
                const elems = self.store.idsOf(t.list_data);
                if (elems.len == 0) return null;
                // Widen tuple elements from literals to their base types,
                // matching TypeScript's behavior: array methods treat tuples
                // as if indexed by arbitrary keys, not numeric indices.
                var buf: [32]TypeId = undefined;
                var n: usize = 0;
                for (elems) |elem| {
                    if (n >= buf.len) break;
                    const peeled = self.peelRestElem(elem);
                    const et = self.store.get(peeled);
                    const widened = switch (et.kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        .bigint_literal => tymod.ID_BIGINT,
                        else => peeled,
                    };
                    buf[n] = widened;
                    n += 1;
                }
                if (n == 0) return null;
                if (n == 1) return buf[0];
                return self.store.unionOf(buf[0..n]) catch elems[0];
            },
            .union_t => {
                var buf: [16]TypeId = undefined;
                var n: usize = 0;
                for (self.store.idsOf(t.list_data)) |m| {
                    const e = self.arrayMethodElementTypeOf(m) orelse return null;
                    if (n >= buf.len) return null;
                    buf[n] = e;
                    n += 1;
                }
                if (n == 0) return null;
                if (n == 1) return buf[0];
                return self.store.unionOf(buf[0..n]) catch null;
            },
            else => return null,
        }
    }

    /// `keyof T` — when T resolves to an object-like type with known
    /// properties, return the union of string-literal property names.
    /// Falls back to ID_STRING when T can't be statically inspected.
    fn resolveKeyofType(self: *Checker, inner: NodeIndex) TypeId {
        if (inner == .none) return tymod.ID_STRING;
        const inner_ty = self.resolveTypeNode(inner);
        return self.keyofOf(inner_ty);
    }

    fn keyofOf(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        // Object: union of own prop names.
        if (t.kind == .object_t) {
            var buf: [32]TypeId = undefined;
            var n: usize = 0;
            for (self.store.propsOf(t.object_props)) |p| {
                if (n >= buf.len) break;
                buf[n] = self.store.stringLiteral(p.name) catch continue;
                n += 1;
            }
            if (n == 0) return tymod.ID_NEVER;
            if (n == 1) return buf[0];
            return self.store.unionOf(buf[0..n]) catch tymod.ID_STRING;
        }
        // type_ref to user/interface — resolve and recurse.
        if (t.kind == .type_ref) {
            if (self.resolveDeclaredType(t.name)) |resolved| {
                if (!resolved.eq(id)) return self.keyofOf(resolved);
            }
        }
        // Array: keyof T[] includes number-coercible string indices +
        // 'length' / 'push' / 'pop' / etc.  TS technically returns a
        // huge union here; conservative: return number (the rule's
        // common case for `T[number]` shape).
        if (t.kind == .array_t or t.kind == .readonly_array_t or t.kind == .tuple_t) {
            return tymod.ID_NUMBER;
        }
        return tymod.ID_STRING;
    }

    /// `typeof x` in type position — resolve to the value-side type of
    /// the identifier `x`.  Falls back to ID_UNKNOWN when the inner
    /// expression isn't a bare identifier or no value is found.
    fn resolveTypeofType(self: *Checker, ty_node: NodeIndex) TypeId {
        const d = self.ast_ref.nodeData(ty_node);
        var inner = d.lhs;
        if (inner == .none) return tymod.ID_UNKNOWN;
        while (self.ast_ref.nodeTag(inner) == .grouping_expr) inner = self.ast_ref.nodeData(inner).lhs;
        const inner_tag = self.ast_ref.nodeTag(inner);
        // In type position, `typeof A` has lhs = ts_type_reference (not .identifier).
        // Accept either form — both carry the name in the main_token.
        if (inner_tag != .identifier and inner_tag != .ts_type_reference) return tymod.ID_UNKNOWN;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(inner));
        if (name.len == 0) return tymod.ID_UNKNOWN;
        // Cycle break: a `typeof name` that re-enters while already resolving the
        // same name (self/mutually-recursive function types) resolves to unknown.
        for (self.typeof_names[0..self.typeof_n]) |n| {
            if (std.mem.eql(u8, n, name)) return tymod.ID_UNKNOWN;
        }
        if (self.typeof_n >= self.typeof_names.len) return tymod.ID_UNKNOWN;
        self.typeof_names[self.typeof_n] = name;
        self.typeof_n += 1;
        defer self.typeof_n -= 1;
        // `typeof ClassName` → the static (constructor) type so prefer-readonly's
        // getTypeToClassRelation returns Class (objectFlags.Anonymous) rather than
        // Instance (Interface) for modifications via `that = {} as typeof Foo & …`.
        if (self.classAstNodeByName(name)) |class_node| {
            return self.buildClassStaticType(class_node, name);
        }
        // Find a declarator binding the same name and use its inferred type.
        if (self.typeOfNameByAstSearch(name)) |t| {
            // `const x = Symbol(...)` — TypeScript treats `typeof x` as a unique
            // symbol type (a finite singleton).  Our checker infers ID_UNKNOWN for
            // the Symbol() call.  Return a string_literal carrying the variable name
            // as a sentinel so switch-exhaustiveness-check can treat it as finite
            // and match it against an identifier case `case x:`.
            if (t.eq(tymod.ID_UNKNOWN) and self.constInitIsSymbolCall(name)) {
                return self.store.stringLiteral(name) catch t;
            }
            return t;
        }
        if (self.global_value_types.get(name)) |t| return t;
        // Unresolved typeof reference → `any` (safe default for unmodeled types).
        return tymod.ID_ANY;
    }

    /// Returns the class_decl AST node for the class named `name`, or null.
    pub fn classAstNodeByName(self: *Checker, name: []const u8) ?NodeIndex {
        const ni = self.type_decl_nodes.get(name) orelse return null;
        if (self.ast_ref.nodeTag(ni) == .class_decl) return ni;
        return null;
    }

    /// Returns true when `const <name> = Symbol(...)` exists in the AST —
    /// i.e., a declarator whose lhs is the identifier `name` and whose rhs
    /// is a call_expr whose callee is the global `Symbol` identifier.
    pub fn constInitIsSymbolCall(self: *Checker, name: []const u8) bool {
        const list = self.value_decl_by_name.get(name) orelse return false;
        for (list.items) |ni| {
            if (self.ast_ref.nodeTag(ni) != .declarator) continue;
            const data = self.ast_ref.nodeData(ni);
            if (data.lhs == .none or data.rhs == .none) continue;
            if (self.ast_ref.nodeTag(data.lhs) != .identifier) continue;
            const dn = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(data.lhs));
            if (!std.mem.eql(u8, dn, name)) continue;
            // rhs must be a call_expr whose callee is the `Symbol` identifier.
            if (self.ast_ref.nodeTag(data.rhs) != .call_expr) continue;
            const callee = self.ast_ref.nodeData(data.rhs).lhs;
            if (callee == .none) continue;
            if (self.ast_ref.nodeTag(callee) != .identifier) continue;
            const callee_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(callee));
            return std.mem.eql(u8, callee_name, "Symbol");
        }
        return false;
    }

    /// Build a `<T extends X, U>` prefix string from the AST type-params range.
    /// Returns an owned slice or null if no type params / allocation failed.
    fn buildTypeParamsPrefix(self: *Checker, tp_start: u32, tp_end: u32) ?[]const u8 {
        if (tp_start >= tp_end) return null;
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        if (tp_end > ext_len) return null;
        const tp_nodes = self.ast_ref.extra_data[tp_start..tp_end];
        var buf: std.ArrayList(u8) = .empty;
        buf.append(self.gpa, '<') catch { buf.deinit(self.gpa); return null; };
        var count: usize = 0;
        for (tp_nodes) |raw| {
            const tp: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(tp) != .ts_type_parameter) continue;
            if (count > 0) buf.appendSlice(self.gpa, ", ") catch { buf.deinit(self.gpa); return null; };
            const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp));
            buf.appendSlice(self.gpa, name) catch { buf.deinit(self.gpa); return null; };
            const tp_data = self.ast_ref.nodeData(tp);
            if (tp_data.lhs != .none) {
                const constraint_ty = self.resolveTypeNode(tp_data.lhs);
                if (self.typeToString(constraint_ty)) |cs| {
                    buf.appendSlice(self.gpa, " extends ") catch { self.gpa.free(cs); buf.deinit(self.gpa); return null; };
                    buf.appendSlice(self.gpa, cs) catch { self.gpa.free(cs); buf.deinit(self.gpa); return null; };
                    self.gpa.free(cs);
                } else |_| {}
            }
            if (tp_data.rhs != .none) {
                const default_ty = self.resolveTypeNode(tp_data.rhs);
                if (self.typeToString(default_ty)) |ds| {
                    buf.appendSlice(self.gpa, " = ") catch { self.gpa.free(ds); buf.deinit(self.gpa); return null; };
                    buf.appendSlice(self.gpa, ds) catch { self.gpa.free(ds); buf.deinit(self.gpa); return null; };
                    self.gpa.free(ds);
                } else |_| {}
            }
            count += 1;
        }
        if (count == 0) { buf.deinit(self.gpa); return null; }
        buf.append(self.gpa, '>') catch { buf.deinit(self.gpa); return null; };
        return buf.toOwnedSlice(self.gpa) catch { buf.deinit(self.gpa); return null; };
    }

    /// Record the generic type-parameter prefix for a function TypeId so that
    /// typeToStringInner can emit the correct `<T>(…) => …` form.
    /// Reads type parameter names from the AST extra_data range [tp_start, tp_end).
    /// First-writer wins for interned types (identical structural signatures share one TypeId).
    fn registerFnTypeParams(self: *Checker, fn_type: TypeId, tp_start: u32, tp_end: u32) void {
        if (self.fn_type_params.contains(fn_type)) return;
        const s = self.buildTypeParamsPrefix(tp_start, tp_end) orelse return;
        self.fn_type_params.put(self.gpa, fn_type, s) catch self.gpa.free(s);
    }

    /// Record the generic type-parameter prefix for a specific signature slot
    /// (keyed by signature pool index) for multi-sig overload rendering.
    fn registerSigTypeParams(self: *Checker, sig_pool_idx: u32, tp_start: u32, tp_end: u32) void {
        if (self.sig_type_params.contains(sig_pool_idx)) return;
        const s = self.buildTypeParamsPrefix(tp_start, tp_end) orelse return;
        self.sig_type_params.put(self.gpa, sig_pool_idx, s) catch self.gpa.free(s);
    }

    /// Extract type parameter names from a prefix like `"<T>"`, `"<T extends X, U>"`.
    /// Returns the count of names found; names are stored in `out[0..count]`.
    /// Handles nested `<>` correctly so commas inside constraints are ignored.
    fn extractTpNames(prefix: []const u8, out: [][]const u8) usize {
        if (prefix.len < 2 or prefix[0] != '<') return 0;
        const inner = prefix[1 .. prefix.len - 1];
        var count: usize = 0;
        var depth: usize = 0;
        var seg_start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const c: u8 = if (i < inner.len) inner[i] else ',';
            if (c == '<') { depth += 1; continue; }
            if (c == '>') { if (depth > 0) depth -= 1; continue; }
            if (c == ',' and depth == 0) {
                const seg = std.mem.trim(u8, inner[seg_start..i], " ");
                const name_end = std.mem.indexOfScalar(u8, seg, ' ') orelse seg.len;
                if (name_end > 0 and count < out.len) {
                    out[count] = seg[0..name_end];
                    count += 1;
                }
                seg_start = i + 1;
            }
        }
        return count;
    }

    /// Build a renamed type-params prefix string for a multi-sig overload.
    /// For each name in `original_prefix` that already appears in `seen[0..seen_len]`,
    /// generates a fresh name (e.g. T → T_1, T_1 → T_2) and:
    ///   - Writes the rename into `self.tp_renames` so typeToStringInner can use it.
    ///   - Adds original and renamed names to `seen_buf[seen_len..]`, updating `seen_len.*`.
    /// Returns an owned renamed prefix or null if no renames were needed (caller emits original).
    /// Caller must call `self.tp_renames.clearRetainingCapacity()` before each call.
    /// `name_pool` is caller-provided stack storage for fresh name bytes (non-owning slices).
    fn applyTpRenames(
        self: *Checker,
        original_prefix: []const u8,
        seen_buf: [][]const u8,
        seen_len: *usize,
        name_pool: []u8,
        name_pool_pos: *usize,
    ) ?[]const u8 {
        var names_buf: [16][]const u8 = undefined;
        const n = extractTpNames(original_prefix, &names_buf);
        if (n == 0) return null;

        var any_rename = false;
        for (names_buf[0..n]) |name| {
            var conflict = false;
            for (seen_buf[0..seen_len.*]) |s| {
                if (std.mem.eql(u8, s, name)) { conflict = true; break; }
            }
            if (!conflict) {
                if (seen_len.* < seen_buf.len) { seen_buf[seen_len.*] = name; seen_len.* += 1; }
                continue;
            }
            // Generate a fresh name: name_1, name_2, ...
            any_rename = true;
            var suffix: u32 = 1;
            var fresh_slice: []const u8 = name;
            var fbuf: [64]u8 = undefined;
            while (suffix < 100) : (suffix += 1) {
                const candidate = std.fmt.bufPrint(&fbuf, "{s}_{d}", .{ name, suffix }) catch break;
                var taken = false;
                for (seen_buf[0..seen_len.*]) |s| {
                    if (std.mem.eql(u8, s, candidate)) { taken = true; break; }
                }
                if (!taken) {
                    // Copy into caller-provided name_pool (stack storage, no heap alloc)
                    if (name_pool_pos.* + candidate.len <= name_pool.len) {
                        @memcpy(name_pool[name_pool_pos.*..][0..candidate.len], candidate);
                        fresh_slice = name_pool[name_pool_pos.*..][0..candidate.len];
                        name_pool_pos.* += candidate.len;
                    }
                    break;
                }
            }
            self.tp_renames.put(self.gpa, name, fresh_slice) catch {};
            if (seen_len.* < seen_buf.len) { seen_buf[seen_len.*] = fresh_slice; seen_len.* += 1; }
            if (seen_len.* < seen_buf.len) { seen_buf[seen_len.*] = name; seen_len.* += 1; }
        }

        if (!any_rename) return null;

        // Build the renamed prefix string from the original, substituting names.
        var out: std.ArrayList(u8) = .empty;
        out.append(self.gpa, '<') catch { out.deinit(self.gpa); return null; };
        for (names_buf[0..n], 0..) |name, ni| {
            if (ni > 0) out.appendSlice(self.gpa, ", ") catch { out.deinit(self.gpa); return null; };
            const display = self.tp_renames.get(name) orelse name;
            out.appendSlice(self.gpa, display) catch { out.deinit(self.gpa); return null; };
            // Find the constraint part (everything after "name" in original_prefix segment).
            // Re-parse original_prefix to find this segment and append the constraint.
            const inner = original_prefix[1 .. original_prefix.len - 1];
            var depth2: usize = 0;
            var seg_s: usize = 0;
            var seg_idx: usize = 0;
            var ii: usize = 0;
            while (ii <= inner.len) : (ii += 1) {
                const c2: u8 = if (ii < inner.len) inner[ii] else ',';
                if (c2 == '<') { depth2 += 1; continue; }
                if (c2 == '>') { if (depth2 > 0) depth2 -= 1; continue; }
                if (c2 == ',' and depth2 == 0) {
                    if (seg_idx == ni) {
                        // Append constraint part of this segment
                        const seg = std.mem.trim(u8, inner[seg_s..ii], " ");
                        const name_end2 = std.mem.indexOfScalar(u8, seg, ' ') orelse seg.len;
                        if (name_end2 < seg.len) {
                            out.appendSlice(self.gpa, seg[name_end2..]) catch { out.deinit(self.gpa); return null; };
                        }
                        break;
                    }
                    seg_s = ii + 1;
                    seg_idx += 1;
                }
            }
        }
        out.append(self.gpa, '>') catch { out.deinit(self.gpa); return null; };
        return out.toOwnedSlice(self.gpa) catch { out.deinit(self.gpa); return null; };
    }

    /// Build a function_t from an fn_decl / async_fn_decl / etc. node.
    /// Params come from the FnData params SubRange; each param's
    /// declared annotation (if any) becomes its TypeId, defaulting to
    /// `unknown` when un-annotated.  Return type comes from the
    /// declared annotation, else falls back to body-inference for
    /// arrow-expression-body, else `unknown`.
    fn functionTypeFromFnDecl(self: *Checker, fn_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(fn_node);
        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
        const fn_tag = self.ast_ref.nodeTag(fn_node);
        const is_async = switch (fn_tag) {
            .async_fn_decl, .async_fn_expr, .async_generator_fn_decl,
            .async_generator_fn_expr => true,
            else => false,
        };
        const is_generator = switch (fn_tag) {
            .generator_fn_decl, .generator_fn_expr,
            .async_generator_fn_decl, .async_generator_fn_expr => true,
            else => false,
        };
        const result = self.buildFunctionType(fd.params, fd.params_end, fd.return_type, fd.body, is_async, is_generator);
        if (fd.type_params < fd.type_params_end)
            self.registerFnTypeParams(result, fd.type_params, fd.type_params_end);
        return result;
    }

    /// Build a function_t from an arrow_fn / async_arrow_fn node.
    fn functionTypeFromArrow(self: *Checker, arrow_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(arrow_node);
        const ad = self.ast_ref.extraData(ast.ArrowData, @intFromEnum(data.lhs));
        const is_async = self.ast_ref.nodeTag(arrow_node) == .async_arrow_fn;
        const fn_ty = self.buildFunctionType(ad.params_start, ad.params_end, ad.return_type, ad.body, is_async, false);
        // ArrowData has no type_params field. For generic arrows <T>(params) => body,
        // the parser stores type param node indices in extra_data immediately before
        // params_start. Only generic arrows have type params: non-async generic arrows
        // start with '<' (less_than main_token); async generic arrows have 'async'
        // as main_token and '<' as the very next token.
        const main_tok = self.ast_ref.nodeMainToken(arrow_node);
        const main_tag = self.ast_ref.tokenTag(main_tok);
        const tok_count: u32 = @intCast(self.ast_ref.tokens.len);
        const is_generic_arrow = main_tag == .less_than or
            (is_async and main_tag == .kw_async and
             main_tok + 1 < tok_count and
             self.ast_ref.tokenTag(main_tok + 1) == .less_than);
        if (is_generic_arrow and !self.fn_type_params.contains(fn_ty)) {
            const ext = self.ast_ref.extra_data;
            const total_nodes: u32 = @intCast(self.ast_ref.nodes.len);
            const tp_end = ad.params_start;
            var tp_start = tp_end;
            while (tp_start > 0) {
                const raw = ext[tp_start - 1];
                if (raw >= total_nodes) break;
                const ni: NodeIndex = @enumFromInt(raw);
                if (self.ast_ref.nodeTag(ni) != .ts_type_parameter) break;
                tp_start -= 1;
            }
            if (tp_start < tp_end) self.registerFnTypeParams(fn_ty, tp_start, tp_end);
        }
        return fn_ty;
    }

    fn buildFunctionType(
        self: *Checker,
        params_start: u32,
        params_end: u32,
        return_type_node: NodeIndex,
        body_for_inference: NodeIndex,
        is_async: bool,
        is_generator: bool,
    ) TypeId {
        const sig = self.buildSignatureRaw(params_start, params_end, return_type_node, body_for_inference, is_async, is_generator) orelse return tymod.ID_UNKNOWN;
        return self.store.functionType(sig) catch tymod.ID_UNKNOWN;
    }

    /// Build a Signature (appending params to the store's param pool) without
    /// creating a function_t TypeId.  Used to collect multiple signatures for
    /// overloaded function declarations before merging them into one function_t.
    fn buildSignatureRaw(
        self: *Checker,
        params_start: u32,
        params_end: u32,
        return_type_node: NodeIndex,
        body_for_inference: NodeIndex,
        is_async: bool,
        is_generator: bool,
    ) ?tymod.Signature {
        // Resolve each param's type from its annotation.
        // Use type-position mode so type-parameter references like `T` in
        // `<T>(x: T) => T` render as the named param, not as the constraint.
        self.type_pos_depth += 1;
        defer self.type_pos_depth -= 1;
        var param_buf: [16]tymod.TypeId = undefined;
        var name_buf: [16][]const u8 = undefined;
        var opt_buf: [16]bool = undefined;
        var count: usize = 0;
        var rest_idx: u16 = 0xFFFF;
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        if (params_start <= params_end and params_end <= ext_len) {
            const params = self.ast_ref.extra_data[params_start..params_end];
            for (params) |raw| {
                if (count >= param_buf.len) break;
                const param: NodeIndex = @enumFromInt(raw);
                // Detect a rest parameter (`...args`) — peel default-value and
                // parameter-property wrappers, then check for rest_element.
                var pn = param;
                const is_default = self.ast_ref.nodeTag(pn) == .assignment_pattern;
                if (is_default) pn = self.ast_ref.nodeData(pn).lhs;
                if (self.ast_ref.nodeTag(pn) == .ts_parameter_property) pn = self.ast_ref.nodeData(pn).lhs;
                const is_rest = self.ast_ref.nodeTag(pn) == .rest_element;
                if (is_rest) rest_idx = @intCast(count);
                var pty = self.paramDeclaredType(param);
                // JSDoc `@param {T}` supplies the type for an unannotated JS
                // parameter, so the rendered signature shows `(x: number)`.
                if (self.checker_opts.is_js_file and !self.paramHasAnnotation(param) and
                    (pty.eq(tymod.ID_ANY) or pty.eq(tymod.ID_UNKNOWN)))
                {
                    const jbind = if (self.ast_ref.nodeTag(pn) == .identifier) pn else param;
                    if (self.jsdocParamBindingType(jbind)) |jt| pty = jt;
                }
                // An un-annotated first parameter of a Promise rejection
                // callback (`p.catch(e=>…)` / `p.then(onF, e=>…)`) is `any`,
                // not `unknown` — drives use-unknown-in-catch-callback-variable.
                if (count == 0 and pty.eq(tymod.ID_UNKNOWN) and !self.paramHasAnnotation(param)) {
                    if (self.contextualPromiseRejectionParamType(param)) |t| pty = t;
                }
                // Rest parameters are always array-typed in TypeScript.
                // `...args` (unannotated) → any[], `...args: any` → any[].
                // Skip wrapping when the type is already an array/tuple/union
                // or a named type ref (could be a generic extending any[]).
                if (is_rest) {
                    const pty_k = self.store.get(pty).kind;
                    if (pty.eq(tymod.ID_ANY) or pty.eq(tymod.ID_UNKNOWN)) {
                        pty = self.store.arrayOf(tymod.ID_ANY) catch pty;
                    } else if (pty_k != .array_t and pty_k != .readonly_array_t and
                               pty_k != .tuple_t and pty_k != .union_t and
                               pty_k != .type_ref and pty_k != .type_param)
                    {
                        pty = self.store.arrayOf(pty) catch pty;
                    }
                }
                param_buf[count] = pty;
                name_buf[count] = self.paramName(param);
                // A param is optional if it has a default value, or has an
                // explicit `?` marker between the identifier and the annotation.
                opt_buf[count] = is_default or self.paramHasOptionalMarker(pn);
                count += 1;
            }
        }
        // Resolve return type.  Declared annotation wins; arrow with
        // expression body uses its body type directly; block-body
        // returns are inferred by walking direct `return <expr>;`
        // statements in the body (no nested function descent).
        // `declare function f(...)` with no return annotation and no body:
        // TypeScript infers `any` as the return type. Use `any` as the initial
        // fallback; body inference or annotation will override it below.
        var ret_ty: TypeId = if (body_for_inference == .none) tymod.ID_ANY else tymod.ID_UNKNOWN;
        var predicate_param_idx: u16 = 0xFFFF;
        var predicate_target: TypeId = TypeId.none;
        var is_assertion: bool = false;
        const was_annotated = return_type_node != .none and
            self.ast_ref.nodeTag(return_type_node) == .ts_type_annotation;
        if (was_annotated) {
            const ty_inner = self.ast_ref.nodeData(return_type_node).lhs;
            // `name is X` type-predicate return — record the predicate
            // info AND treat the actual return type as boolean.
            if (self.ast_ref.nodeTag(ty_inner) == .ts_type_predicate) {
                const pd = self.ast_ref.nodeData(ty_inner);
                // Distinguish `asserts x [is X]` (main_token = "asserts")
                // from `x is X` (main_token = the param name).
                const pred_main = self.ast_ref.nodeMainToken(ty_inner);
                is_assertion = std.mem.eql(u8, self.ast_ref.tokenText(pred_main), "asserts");
                // pd.lhs = param-name identifier (or this_expr).
                if (pd.lhs != .none and self.ast_ref.nodeTag(pd.lhs) == .identifier) {
                    const pred_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(pd.lhs));
                    // Find which param has this name.  `this` parameters
                    // are a TS-only declaration of the receiver type and
                    // don't take an argument slot — exclude them from
                    // the index used to match call-site arg positions.
                    var pi: usize = 0;
                    if (params_start <= params_end and params_end <= ext_len) {
                        const params = self.ast_ref.extra_data[params_start..params_end];
                        for (params) |raw| {
                            const p_node: NodeIndex = @enumFromInt(raw);
                            const pn = self.paramName(p_node);
                            if (std.mem.eql(u8, pn, "this")) continue;
                            if (pn.len > 0 and std.mem.eql(u8, pn, pred_name)) {
                                predicate_param_idx = @intCast(pi);
                                break;
                            }
                            pi += 1;
                        }
                    }
                    if (pd.rhs != .none) predicate_target = self.resolveTypeNode(pd.rhs);
                }
                // Assertion-style: return type is void (not boolean).
                ret_ty = if (is_assertion) tymod.ID_VOID else tymod.ID_BOOLEAN;
            } else {
                ret_ty = self.resolveTypeNode(ty_inner);
            }
        } else if (self.jsdocReturnTypeForBody(body_for_inference)) |jret| {
            // JSDoc `@returns {T}` supplies the return type in JS when there's
            // no TS annotation.  Treated like body inference so async/generator
            // wrapping still applies below.
            ret_ty = jret;
        } else if (body_for_inference != .none) {
            const btag = self.ast_ref.nodeTag(body_for_inference);
            if (btag != .block_stmt) {
                const raw_ret = self.typeOf(body_for_inference);
                // Widen primitive literal types in arrow expression bodies to their base types.
                const ret_info = self.store.get(raw_ret);
                ret_ty = switch (ret_info.kind) {
                    .string_literal => tymod.ID_STRING,
                    .number_literal => tymod.ID_NUMBER,
                    .bigint_literal => tymod.ID_BIGINT,
                    .boolean_literal => tymod.ID_BOOLEAN,
                    else => raw_ret,
                };
            } else {
                ret_ty = self.inferBlockReturn(body_for_inference);
            }
            // In non-strict mode, null/undefined return types widen to any (same rule as var decls).
            if (!self.checker_opts.strict_null_checks) {
                const ret_info = self.store.get(ret_ty);
                if (ret_info.kind == .null_t or ret_info.kind == .undefined_t) ret_ty = tymod.ID_ANY;
            }
        }
        // A generator function returns Generator<…> (async: AsyncGenerator<…>)
        // at the call site — what backs await-thenable's for-await `Symbol.
        // asyncIterator` check. An explicit return annotation (e.g.
        // `: AsyncIterableIterator<T>`) is trusted as-is; only body-inferred
        // generators are wrapped. Generators are NOT additionally Promise-wrapped.
        if (is_generator) {
            if (!was_annotated) {
                const gen_name: []const u8 = if (is_async) "AsyncGenerator" else "Generator";
                // Generator<T, TReturn, TNext>: T = yielded type, TReturn = return type, TNext = unknown.
                const t_yield = if (body_for_inference != .none)
                    self.inferYieldType(body_for_inference)
                else
                    tymod.ID_UNKNOWN;
                const t_return = if (ret_ty.eq(tymod.ID_UNKNOWN)) tymod.ID_VOID else ret_ty;
                ret_ty = self.store.typeRef(gen_name, &.{ t_yield, t_return, tymod.ID_UNKNOWN }) catch ret_ty;
            }
        }
        // Async (non-generator) functions return Promise<T> at the call site,
        // even if the body's return type is `T`.  Wrap unless the user already
        // annotated `: Promise<T>` (avoid double-wrapping).
        else if (is_async and !is_assertion and !ret_ty.eq(tymod.ID_UNKNOWN)) {
            const rt = self.store.get(ret_ty);
            const already_promise = rt.kind == .type_ref and std.mem.eql(u8, rt.name, "Promise");
            if (!already_promise) {
                ret_ty = self.store.typeRef("Promise", &.{ret_ty}) catch ret_ty;
            }
        } else if (is_async and ret_ty.eq(tymod.ID_UNKNOWN)) {
            ret_ty = self.store.typeRef("Promise", &.{tymod.ID_UNKNOWN}) catch ret_ty;
        }
        const param_range = self.store.appendSignatureParamsFull(param_buf[0..count], name_buf[0..count], opt_buf[0..count]) catch return null;
        return .{
            .params_start = param_range.start,
            .params_end = param_range.end,
            .return_type = ret_ty,
            .is_async = is_async,
            .predicate_param_index = predicate_param_idx,
            .predicate_target = predicate_target,
            .is_assertion = is_assertion,
            .rest_param_index = rest_idx,
        };
    }

    /// Build a function_t whose signatures are the union of ALL call-visible
    /// overload declarations for `fn_name` (fn_decl / ts_declare_function nodes
    /// with NO body).  The implementation signature (with body) is intentionally
    /// excluded — TypeScript does not expose it as a call signature.
    ///
    /// Returns null when no call-visible overloads are found.
    fn functionTypeFromAllOverloads(self: *Checker, fn_name: []const u8) ?TypeId {
        var sig_buf: [16]tymod.Signature = undefined;
        var tp_buf: [16]struct { start: u32, end: u32 } = undefined;
        var sig_count: usize = 0;
        var has_impl: bool = false; // true if any declaration has a body
        const list = self.value_decl_by_name.get(fn_name) orelse return null;
        for (list.items) |ni| {
            if (sig_count >= sig_buf.len) break;
            const t = self.ast_ref.nodeTag(ni);
            switch (t) {
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .ts_declare_function => {
                    const data = self.ast_ref.nodeData(ni);
                    if (data.lhs == .none) continue;
                    const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
                    if (fd.name == .none) continue;
                    const dn = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(fd.name));
                    if (!std.mem.eql(u8, dn, fn_name)) continue;
                    // Implementation signatures (with body) are not call-visible.
                    if (fd.body != .none) { has_impl = true; continue; }
                    const is_async = switch (t) {
                        .async_fn_decl, .async_generator_fn_decl => true,
                        else => false,
                    };
                    const is_generator = switch (t) {
                        .generator_fn_decl, .async_generator_fn_decl => true,
                        else => false,
                    };
                    const sig = self.buildSignatureRaw(fd.params, fd.params_end, fd.return_type, .none, is_async, is_generator) orelse continue;
                    sig_buf[sig_count] = sig;
                    tp_buf[sig_count] = .{ .start = fd.type_params, .end = fd.type_params_end };
                    sig_count += 1;
                },
                else => {},
            }
        }
        if (sig_count == 0) return null;
        const sig_list = self.store.appendSignatures(sig_buf[0..sig_count]) catch return null;
        for (tp_buf[0..sig_count], 0..) |tp, i| {
            if (tp.start < tp.end) {
                const pool_idx: u32 = sig_list.start + @as(u32, @intCast(i));
                self.registerSigTypeParams(pool_idx, tp.start, tp.end);
            }
        }
        // Mark as overload-set (renders as `{ ... }` object form) only when there are
        // multiple exposed sigs; single-sig functions keep arrow form to avoid false
        // positives from value_decl_by_name mixing nested-scope declarations.
        const fn_ty = self.store.add(.{ .kind = .function_t, .signatures = sig_list, .is_overload_set = sig_count > 1 }) catch return null;
        if (sig_count == 1 and tp_buf[0].start < tp_buf[0].end)
            self.registerFnTypeParams(fn_ty, tp_buf[0].start, tp_buf[0].end);
        return fn_ty;
    }

    /// Build the merged function type from all no-body overload declarations of a
    /// class method (or static method when want_static=true) with the given name.
    /// Works like functionTypeFromAllOverloads but scoped to a single class body.
    /// Returns null when no call-visible overloads are found (single body-only method).
    fn buildClassMethodMergedType(
        self: *Checker,
        class_node: NodeIndex,
        method_name: []const u8,
        want_static: bool,
    ) ?TypeId {
        const cdata = self.ast_ref.nodeData(class_node);
        if (cdata.lhs == .none) return null;
        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
        if (cd.body == .none) return null;
        const body_data = self.ast_ref.nodeData(cd.body);
        const slice = self.directRange(body_data.lhs, body_data.rhs) orelse return null;

        var sig_buf: [8]tymod.Signature = undefined;
        var tp_buf: [8]struct { start: u32, end: u32 } = undefined;
        var sig_count: usize = 0;
        var has_impl_method: bool = false; // any method_def with a body?

        for (slice) |raw| {
            if (sig_count >= sig_buf.len) break;
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) != .method_def) continue;
            if (self.classMemberIsStatic(m) != want_static) continue;
            const mdata = self.ast_ref.nodeData(m);
            if (mdata.lhs == .none or mdata.rhs == .none) continue;
            const ktag = self.ast_ref.nodeTag(mdata.lhs);
            if (ktag != .identifier and ktag != .property_ident) continue;
            const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
            if (!std.mem.eql(u8, key, method_name)) continue;
            const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(mdata.rhs));
            if (md.body != .none) { has_impl_method = true; continue; }
            const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
            const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
            const sig = self.buildSignatureRaw(md.params_start, md.params_end, md.return_type, .none, is_async, is_generator) orelse continue;
            sig_buf[sig_count] = sig;
            tp_buf[sig_count] = .{ .start = md.type_params, .end = md.type_params_end };
            sig_count += 1;
        }
        if (sig_count == 0) return null;
        const sig_list = self.store.appendSignatures(sig_buf[0..sig_count]) catch return null;
        // Register per-signature type params so rendering uses <T> prefixes correctly.
        for (tp_buf[0..sig_count], 0..) |tp, i| {
            if (tp.start < tp.end) {
                const pool_idx: u32 = sig_list.start + @as(u32, @intCast(i));
                self.registerSigTypeParams(pool_idx, tp.start, tp.end);
            }
        }
        const fn_ty = self.store.add(.{ .kind = .function_t, .signatures = sig_list, .is_overload_set = sig_count > 1 }) catch return null;
        // For single-sig, also register fn_type_params for type-param prefix rendering.
        if (sig_count == 1 and tp_buf[0].start < tp_buf[0].end) {
            self.registerFnTypeParams(fn_ty, tp_buf[0].start, tp_buf[0].end);
        }
        return fn_ty;
    }

    /// For a method_def key at a class method declaration, walk up to the containing
    /// class and return the merged overload type.  Returns null when not in a class
    /// context or when there are no no-body overload signatures.
    fn classMethodTypeAtDecl(self: *Checker, method_def_node: NodeIndex, method_name: []const u8) ?TypeId {
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const midx = method_def_node.toInt();
        if (midx >= parents.len) return null;
        var p_idx = parents[midx];
        if (p_idx == NONE) return null;
        // Skip class_body node if present between method_def and class_decl/expr.
        if (p_idx < parents.len) {
            const possible_body: NodeIndex = @enumFromInt(p_idx);
            if (self.ast_ref.nodeTag(possible_body) == .class_body) {
                p_idx = parents[p_idx];
                if (p_idx == NONE) return null;
            }
        }
        const class_node: NodeIndex = @enumFromInt(p_idx);
        const ctag = self.ast_ref.nodeTag(class_node);
        if (ctag != .class_decl and ctag != .class_expr) return null;
        const is_static = self.classMemberIsStatic(method_def_node);
        return self.buildClassMethodMergedType(class_node, method_name, is_static);
    }

    /// Find the same-name, same-staticness getter paired with a set accessor
    /// in the enclosing class body and return its (body-inferred) return type.
    /// tsc gives an unannotated setter parameter the getter's return type.
    fn pairedGetterReturnType(self: *Checker, accessor: NodeIndex, prop_name: []const u8) ?TypeId {
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const midx = accessor.toInt();
        if (midx >= parents.len) return null;
        var p_idx = parents[midx];
        if (p_idx == NONE) return null;
        const possible_body: NodeIndex = @enumFromInt(p_idx);
        if (self.ast_ref.nodeTag(possible_body) == .class_body) {
            p_idx = parents[p_idx];
            if (p_idx == NONE) return null;
        }
        const class_node: NodeIndex = @enumFromInt(p_idx);
        const ctag = self.ast_ref.nodeTag(class_node);
        if (ctag != .class_decl and ctag != .class_expr) return null;
        const cdata = self.ast_ref.nodeData(class_node);
        if (cdata.lhs == .none) return null;
        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
        if (cd.body == .none) return null;
        const body_data = self.ast_ref.nodeData(cd.body);
        const slice = self.directRange(body_data.lhs, body_data.rhs) orelse return null;
        const want_static = self.classMemberIsStatic(accessor);

        for (slice) |raw| {
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) != .getter_def) continue;
            if (self.classMemberIsStatic(m) != want_static) continue;
            const mdata = self.ast_ref.nodeData(m);
            if (mdata.lhs == .none or mdata.rhs == .none) continue;
            const ktag = self.ast_ref.nodeTag(mdata.lhs);
            if (ktag != .identifier and ktag != .property_ident) continue;
            const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
            if (!std.mem.eql(u8, key, prop_name)) continue;
            const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(mdata.rhs));
            const fn_ty = self.buildFunctionType(md.params_start, md.params_end, md.return_type, md.body, false, false);
            const ft = self.store.get(fn_ty);
            if (ft.kind == .function_t) {
                const sigs = self.store.signaturesOf(ft.signatures);
                if (sigs.len > 0) return sigs[0].return_type;
            }
        }
        return null;
    }

    /// Return the identifier name of a function parameter binding.
    fn paramName(self: *Checker, param: NodeIndex) []const u8 {
        var n = param;
        if (self.ast_ref.nodeTag(n) == .ts_parameter_property) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) == .assignment_pattern) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) == .rest_element) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .identifier) return &.{};
        return self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
    }

    /// True when an identifier-type param node has an explicit `?` optional marker.
    /// Checks both the token immediately after the identifier (`success?:` → next
    /// token is `?`) and the source-text fallback for robustness.
    fn paramHasOptionalMarker(self: *Checker, ident_node: NodeIndex) bool {
        if (self.ast_ref.nodeTag(ident_node) != .identifier) return false;
        const name_tok = self.ast_ref.nodeMainToken(ident_node);
        const token_tags = self.ast_ref.tokens.items(.tag);
        const next_tok: u32 = name_tok + 1;
        if (next_tok < token_tags.len and token_tags[next_tok] == .question) return true;
        // Fallback: scan source text after the identifier span.
        const span = self.ast_ref.nodeSpan(ident_node);
        const src = self.ast_ref.source;
        var i: usize = span.end;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (c == ' ' or c == '\t') continue;
            return c == '?';
        }
        return false;
    }

    /// Infer the return type of a block body by union-ing the types
    /// of every `return <expr>;` whose nearest enclosing function is
    /// this block.  Bare `return;` and missing returns contribute
    /// `undefined`.  We approximate the "nearest enclosing function"
    /// check via parent walk.
    fn inferBlockReturn(self: *Checker, body: NodeIndex) TypeId {
        const parents = self.semantic.parent_indices;
        if (parents.len == 0) return tymod.ID_UNKNOWN;
        const body_idx = @intFromEnum(body);
        // The body's direct parent is the function node — anything
        // whose parent chain reaches the body BEFORE another function
        // counts.
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var result: TypeId = TypeId.none;
        var has_bare_return = false;
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const ni: NodeIndex = @enumFromInt(i);
            if (self.ast_ref.nodeTag(ni) != .return_stmt) continue;
            // Walk parents up looking for body — stop if we hit
            // another function first.
            var p = parents[i];
            var reached = false;
            while (p != NONE) : (p = parents[p]) {
                if (p == body_idx) { reached = true; break; }
                const pt = self.ast_ref.nodeTag(@enumFromInt(p));
                if (pt == .fn_decl or pt == .async_fn_decl or pt == .generator_fn_decl or
                    pt == .async_generator_fn_decl or pt == .fn_expr or pt == .async_fn_expr or
                    pt == .generator_fn_expr or pt == .async_generator_fn_expr or
                    pt == .arrow_fn or pt == .async_arrow_fn)
                {
                    break;
                }
            }
            if (!reached) continue;
            const arg = self.ast_ref.nodeData(ni).lhs;
            if (arg == .none) { has_bare_return = true; continue; }
            const raw_t = self.typeOf(arg);
            // Widen primitive literal types in return expressions to their base types.
            const type_info = self.store.get(raw_t);
            const t = switch (type_info.kind) {
                .string_literal => tymod.ID_STRING,
                .number_literal => tymod.ID_NUMBER,
                .bigint_literal => tymod.ID_BIGINT,
                .boolean_literal => tymod.ID_BOOLEAN,
                else => raw_t,
            };
            if (result.eq(TypeId.none)) {
                result = t;
            } else if (!result.eq(t)) {
                // Different from prior — union them.
                const ids = [_]TypeId{ result, t };
                result = self.store.unionOf(&ids) catch result;
            }
        }
        if (result.eq(TypeId.none)) {
            // No return stmts — body may only throw. A body that never
            // falls through (last stmt is throw/guaranteed-terminator) has
            // return type `never`, matching tsc's inference for always-throwing
            // functions.  Otherwise it implicitly returns undefined → void.
            return if (!self.bodyCanFallThrough(body)) tymod.ID_NEVER else tymod.ID_VOID;
        }
        if (has_bare_return) {
            const ids = [_]TypeId{ result, tymod.ID_UNDEFINED };
            result = self.store.unionOf(&ids) catch result;
        }
        // If some code path may fall off the end without returning,
        // union with undefined.  Approximate "falls off" as "last
        // top-level statement isn't a guaranteed-terminator (return,
        // throw, or block ending in one)".
        if (self.bodyCanFallThrough(body)) {
            const ids = [_]TypeId{ result, tymod.ID_UNDEFINED };
            result = self.store.unionOf(&ids) catch result;
        }
        return result;
    }

    /// Infer the yield type `T` for a Generator<T, TReturn, TNext> by collecting
    /// the types of all `yield <expr>` expressions in `body` (direct — not nested
    /// in inner functions) and returning their union.  Returns `never` when there
    /// are no yield statements (a generator that never yields).
    fn inferYieldType(self: *Checker, body: NodeIndex) TypeId {
        const parents = self.semantic.parent_indices;
        if (parents.len == 0) return tymod.ID_NEVER;
        const body_idx = @intFromEnum(body);
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var result: TypeId = TypeId.none;
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const ni: NodeIndex = @enumFromInt(i);
            const ntag = self.ast_ref.nodeTag(ni);
            if (ntag != .yield_expr and ntag != .yield_delegate) continue;
            // Check that this yield is directly inside this body (not an inner generator).
            var p = parents[i];
            var reached = false;
            while (p != NONE) : (p = parents[p]) {
                if (p == body_idx) { reached = true; break; }
                const pt = self.ast_ref.nodeTag(@enumFromInt(p));
                if (pt == .fn_decl or pt == .async_fn_decl or pt == .generator_fn_decl or
                    pt == .async_generator_fn_decl or pt == .fn_expr or pt == .async_fn_expr or
                    pt == .generator_fn_expr or pt == .async_generator_fn_expr or
                    pt == .arrow_fn or pt == .async_arrow_fn)
                {
                    break;
                }
            }
            if (!reached) continue;
            const arg = self.ast_ref.nodeData(ni).lhs;
            const raw_yt: TypeId = if (arg == .none)
                tymod.ID_UNDEFINED
            else if (ntag == .yield_delegate)
                // `yield* iterable` — use element type of the delegated iterable.
                (self.elementTypeOf(self.typeOf(arg)) orelse tymod.ID_UNKNOWN)
            else
                self.typeOf(arg);
            // Widen primitive literals — tsc widens yield types in Generator<T,...>.
            const yt: TypeId = switch (self.store.get(raw_yt).kind) {
                .string_literal => tymod.ID_STRING,
                .number_literal => tymod.ID_NUMBER,
                .bigint_literal => tymod.ID_BIGINT,
                .boolean_literal => tymod.ID_BOOLEAN,
                else => raw_yt,
            };
            if (result.eq(TypeId.none)) {
                result = yt;
            } else if (!result.eq(yt)) {
                result = self.store.unionOf(&.{ result, yt }) catch result;
            }
        }
        return if (result.eq(TypeId.none)) tymod.ID_NEVER else result;
    }

    fn bodyCanFallThrough(self: *Checker, body: NodeIndex) bool {
        if (body == .none) return true;
        if (self.ast_ref.nodeTag(body) != .block_stmt) return true;
        const d = self.ast_ref.nodeData(body);
        const s = @intFromEnum(d.lhs);
        const e = @intFromEnum(d.rhs);
        if (e <= s or e > self.ast_ref.extra_data.len) return true;
        const last_raw = self.ast_ref.extra_data[e - 1];        const last: NodeIndex = @enumFromInt(last_raw);
        return !stmtGuaranteesReturn(self, last);
    }

    fn stmtGuaranteesReturn(self: *Checker, stmt: NodeIndex) bool {
        const t = self.ast_ref.nodeTag(stmt);
        if (t == .return_stmt or t == .throw_stmt) return true;
        if (t == .block_stmt) return !self.bodyCanFallThrough(stmt);
        if (t == .if_else_stmt) {
            const d = self.ast_ref.nodeData(stmt);
            const ed = self.ast_ref.extraData(ast.IfData, @intFromEnum(d.rhs));
            return stmtGuaranteesReturn(self, ed.consequent) and
                stmtGuaranteesReturn(self, ed.alternate);
        }
        return false;
    }


    /// Like paramDeclaredType but uses resolveTypeNodeParamAware so that bare
    /// type-parameter references (e.g. `T` in `<T>(x: T) => T`) resolve to a
    /// genuine type_param TypeId rather than `any`.  Only for type-position function
    /// types (ts_function_type) where the type params are in scope.
    fn paramDeclaredTypeParamAware(self: *Checker, param: NodeIndex) TypeId {
        var node = param;
        if (self.ast_ref.nodeTag(node) == .assignment_pattern) node = self.ast_ref.nodeData(node).lhs;
        if (self.ast_ref.nodeTag(node) == .ts_parameter_property) node = self.ast_ref.nodeData(node).lhs;
        if (self.ast_ref.nodeTag(node) == .rest_element) {
            const rdata = self.ast_ref.nodeData(node);
            if (rdata.rhs != .none and self.ast_ref.nodeTag(rdata.rhs) == .ts_type_annotation) {
                const ty = self.ast_ref.nodeData(rdata.rhs).lhs;
                return self.resolveTypeNodeParamAware(ty);
            }
            return tymod.ID_ANY;
        }
        if (self.ast_ref.nodeTag(node) != .identifier) return tymod.ID_UNKNOWN;
        const bd = self.ast_ref.nodeData(node);
        if (bd.rhs != .none and self.ast_ref.nodeTag(bd.rhs) == .ts_type_annotation) {
            const ty = self.ast_ref.nodeData(bd.rhs).lhs;
            return self.resolveTypeNodeParamAware(ty);
        }
        return tymod.ID_ANY;
    }

    fn paramDeclaredType(self: *Checker, param: NodeIndex) TypeId {
        var node = param;
        // Peel assignment_pattern (default value) — the binding side
        // is what carries the annotation.
        var default_val: NodeIndex = .none;
        if (self.ast_ref.nodeTag(node) == .assignment_pattern) {
            const apd = self.ast_ref.nodeData(node);
            default_val = apd.rhs;
            node = apd.lhs;
        }
        // Peel ts_parameter_property (constructor access modifiers).
        if (self.ast_ref.nodeTag(node) == .ts_parameter_property) {
            node = self.ast_ref.nodeData(node).lhs;
        }
        if (self.ast_ref.nodeTag(node) == .rest_element) {
            const rdata = self.ast_ref.nodeData(node);
            if (rdata.rhs != .none and self.ast_ref.nodeTag(rdata.rhs) == .ts_type_annotation) {
                const ty = self.ast_ref.nodeData(rdata.rhs).lhs;
                return self.resolveTypeNode(ty);
            }
            // Unannotated rest parameters are `any[]` (an array of implicit
            // any), matching tsc with noImplicitAny off.
            return self.store.arrayOf(tymod.ID_ANY) catch tymod.ID_ANY;
        }
        if (self.ast_ref.nodeTag(node) != .identifier) return tymod.ID_UNKNOWN;
        const bd = self.ast_ref.nodeData(node);
        if (bd.rhs != .none and self.ast_ref.nodeTag(bd.rhs) == .ts_type_annotation) {
            const ty = self.ast_ref.nodeData(bd.rhs).lhs;
            return self.resolveTypeNode(ty);
        }
        // No annotation. If there's a default value, infer its widened type —
        // `(a = 3)` → number, `(a = "x")` → string, `(a = true)` → boolean.
        // `null` / `undefined` defaults leave the param as `any` (non-strict).
        if (default_val != .none) {
            const raw = self.typeOf(default_val);
            return switch (self.store.get(raw).kind) {
                .string_literal => tymod.ID_STRING,
                .number_literal => tymod.ID_NUMBER,
                .bigint_literal => tymod.ID_BIGINT,
                .boolean_literal => tymod.ID_BOOLEAN,
                else => tymod.ID_ANY,
            };
        }
        // Unannotated parameters default to `any` to match TypeScript's
        // behavior when noImplicitAny is off (the default). The original design
        // returned `unknown` to avoid spurious unsafe-* fires, but this causes
        // mismatches with tsc's actual inferred type.
        return tymod.ID_ANY;
    }

    /// Map a TS type-position AST node to a TypeId.
    pub fn resolveTypeNode(self: *Checker, ty_node: NodeIndex) TypeId {
        if (ty_node == .none) return tymod.ID_ANY;
        // Depth cap: bail to a safe leaf before a pathological recursive-generic
        // chain overflows the native stack (see resolve_depth).
        if (self.resolve_depth >= 256) return tymod.ID_UNKNOWN;
        self.resolve_depth += 1;
        defer self.resolve_depth -= 1;
        const tag = self.ast_ref.nodeTag(ty_node);
        return switch (tag) {
            .ts_type_reference => self.resolveTypeRef(ty_node),
            .ts_union_type => self.resolveUnion(ty_node),
            .ts_intersection_type => self.resolveIntersection(ty_node),
            .ts_array_type => blk: {
                const elem = self.resolveTypeNode(self.ast_ref.nodeData(ty_node).lhs);
                break :blk self.store.arrayOf(elem) catch tymod.ID_ANY;
            },
            .ts_parenthesized_type => self.resolveTypeNode(self.ast_ref.nodeData(ty_node).lhs),
            // Unresolved-but-not-any cases default to `unknown` so
            // no-unsafe-* rules don't spuriously fire on objects /
            // functions / etc. declared via structural annotations.
            .ts_typeof_type => self.resolveTypeofType(ty_node),
            .ts_keyof_type => blk: {
                // Parser also uses .ts_keyof_type as TSTypeOperator for
                // 'readonly T[]' / 'readonly [T, U]' (TS doesn't share
                // a distinct tag).  Detect the readonly form via the
                // main_token and resolve to the underlying array,
                // converting array_t to readonly_array_t so assignability
                // checks distinguish writable from readonly forms.
                const op_tok = self.ast_ref.nodeMainToken(ty_node);
                const op_text = self.ast_ref.tokenText(op_tok);
                if (std.mem.eql(u8, op_text, "readonly")) {
                    const inner = self.ast_ref.nodeData(ty_node).lhs;
                    const inner_ty = self.resolveTypeNode(inner);
                    const it = self.store.get(inner_ty);
                    if (it.kind == .array_t) {
                        const elems = self.store.idsOf(it.list_data);
                        if (elems.len > 0) break :blk self.store.readonlyArrayOf(elems[0]) catch inner_ty;
                    }
                    break :blk inner_ty;
                }
                // `keyof T` — resolve to the literal union of T's property
                // names when T is structurally inspectable.
                const inner = self.ast_ref.nodeData(ty_node).lhs;
                break :blk self.resolveKeyofType(inner);
            },
            .ts_type_literal => self.resolveTypeLiteral(ty_node),
            .ts_function_type, .ts_constructor_type => self.resolveFunctionType(ty_node),
            .ts_tuple_type => self.resolveTupleType(ty_node),
            .ts_indexed_access_type => self.resolveIndexedAccess(ty_node),
            .ts_conditional_type => self.resolveConditionalType(ty_node),
            .ts_mapped_type => self.resolveMappedType(ty_node),
            .ts_template_literal_type => self.resolveTemplateLiteralType(ty_node),
            // Literal types in type position — parser keeps them as
            // value-style literal nodes.  Preserve the specific literal
            // type so consumers (switch-exhaustiveness, etc.) see the
            // exact value rather than the broad family.
            .string_literal => self.literalString(ty_node),
            .number_literal => self.literalNumber(ty_node),
            .boolean_literal => self.literalBoolean(ty_node),
            .bigint_literal => self.literalBigint(ty_node),
            .null_literal => tymod.ID_NULL,
            // Unhandled type node tags → `any` (safe default for unmodeled syntax).
            else => tymod.ID_ANY,
        };
    }

    /// Build a function_t from a ts_function_type / ts_constructor_type
    /// AST node.  Params live at FnData.params..params_end; return type
    /// lives in FnData.body (the parser reuses the field for type-position
    /// function declarations).
    fn resolveFunctionType(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
        // ts_function_type: return type lives in fd.body (parser reuses the field for type position).
        // Enable type-position mode so type-param references resolve to type_param TypeIds.
        self.type_pos_depth += 1;
        defer self.type_pos_depth -= 1;
        // Walk params manually to capture optional/rest markers (like buildSignatureRaw does).
        var param_buf: [16]tymod.TypeId = undefined;
        var name_buf: [16][]const u8 = undefined;
        var opt_buf: [16]bool = undefined;
        var count: usize = 0;
        var rest_idx: u16 = 0xFFFF;
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        if (fd.params <= fd.params_end and fd.params_end <= ext_len) {
            const params = self.ast_ref.extra_data[fd.params..fd.params_end];
            for (params) |raw| {
                if (count >= param_buf.len) break;
                const param: NodeIndex = @enumFromInt(raw);
                var pn = param;
                const is_default = self.ast_ref.nodeTag(pn) == .assignment_pattern;
                if (is_default) pn = self.ast_ref.nodeData(pn).lhs;
                if (self.ast_ref.nodeTag(pn) == .ts_parameter_property) pn = self.ast_ref.nodeData(pn).lhs;
                if (self.ast_ref.nodeTag(pn) == .rest_element) rest_idx = @intCast(count);
                param_buf[count] = self.paramDeclaredTypeParamAware(param);
                name_buf[count] = self.paramName(param);
                opt_buf[count] = is_default or self.paramHasOptionalMarker(pn);
                count += 1;
            }
        }
        const ret_ty = if (fd.body != .none) self.resolveTypeNodeParamAware(fd.body) else tymod.ID_UNKNOWN;
        const param_range = self.store.appendSignatureParamsFull(param_buf[0..count], name_buf[0..count], opt_buf[0..count]) catch return tymod.ID_UNKNOWN;
        const sig: tymod.Signature = .{
            .params_start = param_range.start,
            .params_end = param_range.end,
            .return_type = ret_ty,
            .rest_param_index = rest_idx,
            .is_construct = (self.ast_ref.nodeTag(ty_node) == .ts_constructor_type),
        };
        const fn_ty = self.store.functionType(sig) catch return tymod.ID_UNKNOWN;
        if (fd.type_params < fd.type_params_end)
            self.registerFnTypeParams(fn_ty, fd.type_params, fd.type_params_end);
        return fn_ty;
    }

    /// Walk a `{ k1: T1; k2: T2; ... }` type literal and build an
    /// object_t in the type store.  Captures named property signatures
    /// only — index signatures (`[key: K]: V`) and call/construct
    /// signatures are out of scope (they need separate representation
    /// in our Type model).  Index signatures cause the property lookup
    /// to fall back to "we don't know" — equivalent to unknown.
    /// Source-scan helper: is there a `?` between the end of `name_node`
    /// Does the `ts_property_signature` member carry a `readonly` modifier?
    /// Scans the token immediately before the name token — for `readonly a: T`
    /// the layout is [..., kw_readonly, identifier(a), ...].
    fn propertyHasReadonlyModifier(self: *Checker, name_node: NodeIndex) bool {
        const name_tok = self.ast_ref.nodeMainToken(name_node);
        if (name_tok == 0) return false;
        const prev_tok: u32 = name_tok - 1;
        const token_tags = self.ast_ref.tokens.items(.tag);
        if (prev_tok >= token_tags.len) return false;
        return token_tags[prev_tok] == .kw_readonly;
    }

    /// and the next colon/lparen/lbrace?  Property signatures lose the
    /// optional marker during parse, so we recover it here.
    fn propertyHasOptionalMarker(self: *Checker, name_node: NodeIndex) bool {
        const span = self.ast_ref.nodeSpan(name_node);
        const src = self.ast_ref.source;
        var i: usize = span.end;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
            return c == '?';
        }
        return false;
    }

    fn resolveTypeLiteral(self: *Checker, ty_node: NodeIndex) TypeId {
        // Members range stored directly in lhs/rhs — see directRange comment.
        const data = self.ast_ref.nodeData(ty_node);
        const member_node_indices = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        var props_buf: [32]tymod.ObjectProp = undefined;
        var prop_count: usize = 0;
        var sig_buf: [8]tymod.Signature = undefined;
        var sig_tp_buf: [8]struct { start: u32, end: u32 } = undefined;
        var sig_count: usize = 0;
        for (member_node_indices) |raw| {
            if (prop_count >= props_buf.len) break;
            const member: NodeIndex = @enumFromInt(raw);
            const m_tag = self.ast_ref.nodeTag(member);
            if (m_tag == .ts_index_signature) {
                // `[k: T]: V` — store under a specific sentinel ("[]L" / "[]U")
                // when the key type is Lowercase<string> / Uppercase<string>, and
                // also always under the generic "[]" sentinel for inferComputedMember
                // and other backward-compat callers.
                const sig_data = self.ast_ref.nodeData(member);
                if (sig_data.rhs == .none) continue;
                const value_node = if (self.ast_ref.nodeTag(sig_data.rhs) == .ts_type_annotation)
                    self.ast_ref.nodeData(sig_data.rhs).lhs
                else
                    sig_data.rhs;
                const value_ty = self.resolveTypeNode(value_node);
                const sentinel = self.indexSigSentinel(member);
                const display = self.indexSigDisplayInfo(member);
                if (prop_count < props_buf.len) {
                    props_buf[prop_count] = .{ .name = sentinel, .type_id = value_ty, .index_key_name = display.key_name, .index_key_is_number = display.is_number };
                    prop_count += 1;
                }
                // Emit generic "[]" for backward compat when key was specific.
                if (!std.mem.eql(u8, sentinel, "[]") and prop_count < props_buf.len) {
                    props_buf[prop_count] = .{ .name = "[]", .type_id = value_ty };
                    prop_count += 1;
                }
                continue;
            }
            if (m_tag == .ts_call_signature or m_tag == .ts_construct_signature) {
                if (sig_count < sig_buf.len) {
                    const mdata = self.ast_ref.nodeData(member);
                    if (mdata.lhs != .none) {
                        const sd = self.ast_ref.extraData(ast.InterfaceSigData, @intFromEnum(mdata.lhs));
                        if (self.buildSignatureRaw(sd.params_start, sd.params_end, sd.return_type, .none, false, false)) |raw_sig| {
                            var sig = raw_sig;
                            sig.is_construct = (m_tag == .ts_construct_signature);
                            sig_buf[sig_count] = sig;
                            sig_tp_buf[sig_count] = .{ .start = sd.type_params, .end = sd.type_params_end };
                            sig_count += 1;
                        }
                    }
                }
                continue;
            }
            if (m_tag != .ts_property_signature and m_tag != .ts_method_signature) continue;
            if (m_tag == .ts_property_signature) {
                const member_data = self.ast_ref.nodeData(member);
                const name_node = member_data.lhs;
                if (name_node == .none) continue;
                const name_tok = self.ast_ref.nodeMainToken(name_node);
                const raw_name = self.ast_ref.tokenText(name_tok);
                const name_tag = self.ast_ref.nodeTag(name_node);
                const name = if ((name_tag == .string_literal or name_tag == .template_literal) and raw_name.len >= 2)
                    raw_name[1 .. raw_name.len - 1]
                else
                    raw_name;
                var prop_ty: TypeId = tymod.ID_ANY;
                if (member_data.rhs != .none and self.ast_ref.nodeTag(member_data.rhs) == .ts_type_annotation) {
                    const ty_inner = self.ast_ref.nodeData(member_data.rhs).lhs;
                    prop_ty = self.resolveTypeNode(ty_inner);
                }
                const optional = propertyHasOptionalMarker(self, name_node);
                const is_readonly = propertyHasReadonlyModifier(self, name_node);
                props_buf[prop_count] = .{ .name = name, .type_id = prop_ty, .optional = optional, .readonly = is_readonly };
                prop_count += 1;
            } else {
                // ts_method_signature: name is in InterfaceSigData.key.
                const sig_data = self.ast_ref.extraData(ast.InterfaceSigData, @intFromEnum(self.ast_ref.nodeData(member).lhs));
                if (sig_data.key == .none) continue;
                const name_tag = self.ast_ref.nodeTag(sig_data.key);
                const name = blk: {
                    // Computed `[Symbol.toPrimitive]` key — synthesize a stable
                    // name so consumers can detect user-defined string coercion.
                    if (name_tag == .member_expr or name_tag == .optional_member_expr) {
                        const kd = self.ast_ref.nodeData(sig_data.key);
                        if (kd.lhs != .none and kd.rhs != .none and
                            self.ast_ref.nodeTag(kd.lhs) == .identifier)
                        {
                            const obj = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(kd.lhs));
                            const prop = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(kd.rhs));
                            if (std.mem.eql(u8, obj, "Symbol") and std.mem.eql(u8, prop, "toPrimitive")) {
                                break :blk "@@toPrimitive";
                            }
                        }
                    }
                    const name_tok = self.ast_ref.nodeMainToken(sig_data.key);
                    const raw_name = self.ast_ref.tokenText(name_tok);
                    break :blk if ((name_tag == .string_literal or name_tag == .template_literal) and raw_name.len >= 2)
                        raw_name[1 .. raw_name.len - 1]
                    else
                        raw_name;
                };
                const fn_ty = self.buildFunctionType(
                    sig_data.params_start,
                    sig_data.params_end,
                    sig_data.return_type,
                    .none,
                    false,
                    false,
                );
                if (sig_data.type_params < sig_data.type_params_end)
                    self.registerFnTypeParams(fn_ty, sig_data.type_params, sig_data.type_params_end);
                const m_optional = propertyHasOptionalMarker(self, sig_data.key);
                props_buf[prop_count] = .{ .name = name, .type_id = fn_ty, .is_method = true, .optional = m_optional };
                prop_count += 1;
            }
        }
        const list = self.store.appendObjectProps(props_buf[0..prop_count]) catch return tymod.ID_UNKNOWN;
        const sig_list = if (sig_count == 0) tymod.SignatureList.empty else blk: {
            const sl = self.store.appendSignatures(sig_buf[0..sig_count]) catch break :blk tymod.SignatureList.empty;
            for (sig_tp_buf[0..sig_count], 0..) |tp, i| {
                if (tp.start < tp.end)
                    self.registerSigTypeParams(sl.start + @as(u32, @intCast(i)), tp.start, tp.end);
            }
            break :blk sl;
        };
        return self.store.add(.{ .kind = .object_t, .object_props = list, .signatures = sig_list }) catch tymod.ID_UNKNOWN;
    }

    /// Evaluate a `ts_mapped_type` AST node into an `object_t` whose
    /// props are the keys named by the constraint, each typed by the
    /// value-type expression.  Only handles cases where the constraint
    /// is a closed set of string-literal types (the form rules care
    /// about, e.g. `{ [K in 'toString' | 'valueOf']: ... }`).
    /// Evaluate a template-literal type into a concrete string-literal
    /// when every interpolation resolves to a string-literal type.
    /// Otherwise approximate as `string`.  Composes results across
    /// unions: each interpolation can expand to multiple variants
    /// when its type is a union of string literals; the result is the
    /// cross-product of all such variants.
    fn resolveTemplateLiteralType(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_STRING;
        // Parts alternate template_element (quasi) and expression
        // (interpolation type).  Accumulate possible string variants.
        var variants: std.ArrayList([]const u8) = .empty;
        defer variants.deinit(self.gpa);
        variants.append(self.gpa, "") catch return tymod.ID_STRING;
        for (slice) |raw| {
            const part: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(part) == .template_element) {
                const tok = self.ast_ref.nodeMainToken(part);
                const start = self.ast_ref.tokenStart(tok);
                const len = self.ast_ref.tokens.items(.len)[tok];
                const src = self.ast_ref.source;
                if (start + len > src.len) return tymod.ID_STRING;
                var span_start = start;
                var span_end: u32 = start + len;
                if (span_start < span_end and (src[span_start] == '`' or src[span_start] == '}')) span_start += 1;
                if (span_end >= span_start + 2 and src[span_end - 1] == '{' and src[span_end - 2] == '$') {                    span_end -= 2;
                } else if (span_end > span_start and src[span_end - 1] == '`') {
                    span_end -= 1;
                }
                const quasi_text = src[span_start..span_end];
                if (quasi_text.len == 0) continue;
                for (variants.items) |*v| {
                    const joined = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ v.*, quasi_text }) catch return tymod.ID_STRING;
                    v.* = joined;
                }
                continue;
            }
            // Interpolation — gather string-literal options.
            const id = self.resolveTypeNode(part);
            var options_buf: [16][]const u8 = undefined;
            const opt_count = self.gatherStringLiteralOptions(id, &options_buf) catch return tymod.ID_STRING;
            if (opt_count == 0) return tymod.ID_STRING;
            const prev_len = variants.items.len;
            // Cross product: each existing variant × each option.
            for (0..opt_count - 1) |_| {
                var dup_i: usize = 0;
                while (dup_i < prev_len) : (dup_i += 1) {
                    variants.append(self.gpa, variants.items[dup_i]) catch return tymod.ID_STRING;
                }
            }
            // Append option suffix to each variant slot.
            var oi: usize = 0;
            while (oi < opt_count) : (oi += 1) {
                var vi: usize = 0;
                while (vi < prev_len) : (vi += 1) {
                    const slot = oi * prev_len + vi;
                    const joined = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ variants.items[slot], options_buf[oi] }) catch return tymod.ID_STRING;
                    variants.items[slot] = joined;
                }
            }
        }
        if (variants.items.len == 0) return tymod.ID_STRING;
        if (variants.items.len == 1) {
            return self.store.add(.{ .kind = .string_literal, .literal_value = .{ .string = variants.items[0] } }) catch tymod.ID_STRING;
        }
        var ids_buf: [16]TypeId = undefined;
        const n = @min(variants.items.len, ids_buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            ids_buf[i] = self.store.add(.{ .kind = .string_literal, .literal_value = .{ .string = variants.items[i] } }) catch return tymod.ID_STRING;
        }
        return self.store.unionOf(ids_buf[0..n]) catch tymod.ID_STRING;
    }

    /// Collect string-literal values from a type id (or a union of
    /// them).  Returns the count written; returns 0 when the type
    /// can't be reduced to concrete strings.
    fn gatherStringLiteralOptions(self: *Checker, id: TypeId, out: *[16][]const u8) !usize {
        const t = self.store.get(id);
        if (t.kind == .string_literal) {
            out[0] = switch (t.literal_value) { .string => |s| s, else => return 0 };
            return 1;
        }
        // Boolean literals → "true" / "false".
        if (t.kind == .boolean_literal) {
            out[0] = switch (t.literal_value) { .boolean => |b| if (b) "true" else "false", else => return 0 };
            return 1;
        }
        // Number literals — the literal_value stores the text representation.
        if (t.kind == .number_literal) {
            out[0] = switch (t.literal_value) { .string => |s| s, else => return 0 };
            return 1;
        }
        if (t.kind == .union_t) {
            var n: usize = 0;
            for (self.store.idsOf(t.list_data)) |m| {
                var tmp: [16][]const u8 = undefined;
                const cnt = self.gatherStringLiteralOptions(m, &tmp) catch return 0;
                if (cnt == 0) return 0;
                if (n + cnt > out.len) return 0;
                @memcpy(out[n..n + cnt], tmp[0..cnt]);
                n += cnt;
            }
            return n;
        }
        return 0;
    }

    /// Evaluate `T extends U ? A : B`.  We support only the cases
    /// where the relation is decidable from the type representations
    /// available — primitive vs primitive, literal vs base type, void
    /// vs void.  When undecidable we union the two branches so
    /// downstream rules don't pick a wrong arm.
    fn resolveConditionalType(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        if (slice.len < 4) return tymod.ID_UNKNOWN;
        const check_node: NodeIndex = @enumFromInt(slice[0]);
        const extends_node: NodeIndex = @enumFromInt(slice[1]);
        const true_node: NodeIndex = @enumFromInt(slice[2]);
        const false_node: NodeIndex = @enumFromInt(slice[3]);
        // Bail conservatively when either side names a type parameter
        // or uses `infer V` — without proper higher-order inference
        // we can't decide the relation and unioning both branches
        // mixes the `infer`-bound branch's unresolved name into
        // downstream types.
        if (typeNodeReferencesUnresolved(self, check_node) or
            typeNodeReferencesUnresolved(self, extends_node))
        {
            return tymod.ID_UNKNOWN;
        }
        const check_ty = self.resolveTypeNode(check_node);
        const extends_ty = self.resolveTypeNode(extends_node);
        switch (self.simpleAssignable(check_ty, extends_ty)) {
            .yes => return self.resolveTypeNode(true_node),
            .no => return self.resolveTypeNode(false_node),
            .unknown => {
                const a = self.resolveTypeNode(true_node);
                const b = self.resolveTypeNode(false_node);
                return self.store.unionOf(&.{ a, b }) catch tymod.ID_UNKNOWN;
            },
        }
    }

    /// Resolve a type node with an active type-param substitution map.
    /// Handles ts_type_reference (subst lookup first), ts_conditional_type
    /// (via resolveConditionalTypeWithSubst), and composite types.  Falls
    /// back to resolveTypeNode for everything else.
    fn resolveTypeNodeWithSubst(
        self: *Checker,
        ty_node: NodeIndex,
        keys: []const []const u8,
        vals: []const TypeId,
    ) TypeId {
        if (ty_node == .none) return tymod.ID_ANY;
        if (keys.len == 0) return self.resolveTypeNode(ty_node);
        // Shares the resolveTypeNode depth budget — generic-alias substitution
        // (`Resolvable<U>` over `type Resolvable<R> = R | PromiseLike<R>`) recurses
        // here, not through resolveTypeNode.
        if (self.resolve_depth >= 256) return tymod.ID_UNKNOWN;
        self.resolve_depth += 1;
        defer self.resolve_depth -= 1;
        const tag = self.ast_ref.nodeTag(ty_node);
        switch (tag) {
            .ts_type_reference => {
                const tok = self.ast_ref.nodeMainToken(ty_node);
                const nm = self.ast_ref.tokenText(tok);
                for (keys, vals) |k, v| {
                    if (std.mem.eql(u8, k, nm)) return v;
                }
                return self.resolveTypeNode(ty_node);
            },
            .ts_conditional_type => return self.resolveConditionalTypeWithSubst(ty_node, keys, vals),
            .ts_parenthesized_type => return self.resolveTypeNodeWithSubst(
                self.ast_ref.nodeData(ty_node).lhs, keys, vals),
            .ts_union_type => {
                const data = self.ast_ref.nodeData(ty_node);
                const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
                var buf: [16]TypeId = undefined;
                const n = @min(slice.len, buf.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    buf[i] = self.resolveTypeNodeWithSubst(@enumFromInt(slice[i]), keys, vals);
                }
                return self.store.unionOf(buf[0..n]) catch tymod.ID_UNKNOWN;
            },
            .ts_intersection_type => {
                const data = self.ast_ref.nodeData(ty_node);
                const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
                var buf: [16]TypeId = undefined;
                const n = @min(slice.len, buf.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    buf[i] = self.resolveTypeNodeWithSubst(@enumFromInt(slice[i]), keys, vals);
                }
                return self.buildIntersection(buf[0..n]);
            },
            .ts_array_type => {
                const elem = self.resolveTypeNodeWithSubst(
                    self.ast_ref.nodeData(ty_node).lhs, keys, vals);
                return self.store.arrayOf(elem) catch tymod.ID_ANY;
            },
            .ts_keyof_type => {
                const op_tok = self.ast_ref.nodeMainToken(ty_node);
                const op_text = self.ast_ref.tokenText(op_tok);
                const inner = self.ast_ref.nodeData(ty_node).lhs;
                if (std.mem.eql(u8, op_text, "readonly")) {
                    // `readonly T[]` — resolve inner with subst, wrap as readonly array.
                    const inner_ty = self.resolveTypeNodeWithSubst(inner, keys, vals);
                    const it = self.store.get(inner_ty);
                    if (it.kind == .array_t) {
                        const elems = self.store.idsOf(it.list_data);
                        if (elems.len > 0) return self.store.readonlyArrayOf(elems[0]) catch inner_ty;
                    }
                    return inner_ty;
                }
                // `keyof T` — resolve inner with subst then apply keyof.
                const inner_ty = self.resolveTypeNodeWithSubst(inner, keys, vals);
                return self.keyofOf(inner_ty);
            },
            .ts_tuple_type => {
                const data = self.ast_ref.nodeData(ty_node);
                const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
                var buf: [16]TypeId = undefined;
                const n = @min(slice.len, buf.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const m: NodeIndex = @enumFromInt(slice[i]);
                    if (self.ast_ref.nodeTag(m) == .spread_element) {
                        const inner = self.resolveTypeNodeWithSubst(self.ast_ref.nodeData(m).lhs, keys, vals);
                        buf[i] = self.store.restOf(inner) catch tymod.ID_ANY;
                    } else {
                        buf[i] = self.resolveTypeNodeWithSubst(m, keys, vals);
                    }
                }
                const list = self.store.appendTypeIds(buf[0..n]) catch return tymod.ID_UNKNOWN;
                return self.store.add(.{ .kind = .tuple_t, .list_data = list }) catch tymod.ID_UNKNOWN;
            },
            else => return self.resolveTypeNode(ty_node),
        }
    }

    /// Evaluate `T extends U ? A : B` with an active substitution map.
    /// Supports distributive conditionals (T is a union) and `infer V` capture.
    fn resolveConditionalTypeWithSubst(
        self: *Checker,
        ty_node: NodeIndex,
        keys: []const []const u8,
        vals: []const TypeId,
    ) TypeId {
        if (self.subst_depth > 16) return tymod.ID_UNKNOWN;
        self.subst_depth += 1;
        defer self.subst_depth -= 1;
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        if (slice.len < 4) return tymod.ID_UNKNOWN;
        const check_node: NodeIndex = @enumFromInt(slice[0]);
        const extends_node: NodeIndex = @enumFromInt(slice[1]);
        const true_node: NodeIndex = @enumFromInt(slice[2]);
        const false_node: NodeIndex = @enumFromInt(slice[3]);

        const check_ty = self.resolveTypeNodeWithSubst(check_node, keys, vals);

        // Distributive: union check type → map conditional over members.
        const check_t = self.store.get(check_ty);
        if (check_t.kind == .union_t) {
            return self.distributeConditional(check_ty, extends_node, true_node, false_node, keys, vals);
        }

        var infer_keys_buf: [4][]const u8 = undefined;
        var infer_vals_buf: [4]TypeId = undefined;
        var infer_count: usize = 0;

        const matched = self.matchConditionalExtends(
            check_ty, extends_node, keys, vals,
            &infer_keys_buf, &infer_vals_buf, &infer_count,
        );

        switch (matched) {
            .yes => {
                if (infer_count == 0) return self.resolveTypeNodeWithSubst(true_node, keys, vals);
                var mk: [8][]const u8 = undefined;
                var mv: [8]TypeId = undefined;
                var nm: usize = 0;
                for (keys, vals) |k, v| { if (nm >= mk.len) break; mk[nm] = k; mv[nm] = v; nm += 1; }
                for (infer_keys_buf[0..infer_count], infer_vals_buf[0..infer_count]) |k, v| {
                    if (nm >= mk.len) break;
                    mk[nm] = k; mv[nm] = v; nm += 1;
                }
                return self.resolveTypeNodeWithSubst(true_node, mk[0..nm], mv[0..nm]);
            },
            .no => return self.resolveTypeNodeWithSubst(false_node, keys, vals),
            .unknown => {
                // The check type is still a free type parameter (e.g. `D` in
                // `D extends Wrapper<infer V> ? V : never` while D is generic):
                // TS leaves the conditional *deferred* (an opaque type, not any).
                // Evaluating both branches would yield a `branch | never` union
                // whose `any` branch makes the whole thing read as `any` — a
                // false positive for the no-unsafe-* rules. Keep it unknown.
                if (check_t.kind == .type_param) return tymod.ID_UNKNOWN;
                const a = blk: {
                    if (infer_count == 0) break :blk self.resolveTypeNodeWithSubst(true_node, keys, vals);
                    var mk: [8][]const u8 = undefined;
                    var mv: [8]TypeId = undefined;
                    var nm: usize = 0;
                    for (keys, vals) |k, v| { if (nm >= mk.len) break; mk[nm] = k; mv[nm] = v; nm += 1; }
                    for (infer_keys_buf[0..infer_count], infer_vals_buf[0..infer_count]) |k, v| {
                        if (nm >= mk.len) break;
                        mk[nm] = k; mv[nm] = v; nm += 1;
                    }
                    break :blk self.resolveTypeNodeWithSubst(true_node, mk[0..nm], mv[0..nm]);
                };
                const b = self.resolveTypeNodeWithSubst(false_node, keys, vals);
                if (a.eq(b)) return a;
                return self.store.unionOf(&.{ a, b }) catch tymod.ID_UNKNOWN;
            },
        }
    }

    /// Try to match `check_ty` against `extends_node`, capturing any
    /// `infer V` bindings along the way.  Returns .yes/.no/.unknown.
    fn matchConditionalExtends(
        self: *Checker,
        check_ty: TypeId,
        extends_node: NodeIndex,
        keys: []const []const u8,
        vals: []const TypeId,
        infer_keys: *[4][]const u8,
        infer_vals: *[4]TypeId,
        infer_count: *usize,
    ) AssignResult {
        var n = extends_node;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        const tag = self.ast_ref.nodeTag(n);

        // `infer V` — always matches; capture the whole check_ty.
        if (tag == .ts_infer_type) {
            const param_node = self.ast_ref.nodeData(n).lhs;
            if (param_node != .none and infer_count.* < infer_keys.len) {
                infer_keys[infer_count.*] = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(param_node));
                infer_vals[infer_count.*] = check_ty;
                infer_count.* += 1;
            }
            return .yes;
        }

        // `Array<infer E>` / `ReadonlyArray<infer E>` pattern.
        if (tag == .ts_type_reference) {
            const nm = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
            if (std.mem.eql(u8, nm, "Array") or std.mem.eql(u8, nm, "ReadonlyArray")) {
                const cht = self.store.get(check_ty);
                if (cht.kind == .array_t or cht.kind == .readonly_array_t) {
                    const first_arg = self.firstTypeArg(n);
                    if (first_arg != .none) {
                        var an = first_arg;
                        while (self.ast_ref.nodeTag(an) == .ts_parenthesized_type) an = self.ast_ref.nodeData(an).lhs;
                        if (self.ast_ref.nodeTag(an) == .ts_infer_type) {
                            const param_node = self.ast_ref.nodeData(an).lhs;
                            if (param_node != .none and infer_count.* < infer_keys.len) {
                                const elems = self.store.idsOf(cht.list_data);
                                infer_keys[infer_count.*] = self.ast_ref.tokenText(
                                    self.ast_ref.nodeMainToken(param_node));
                                infer_vals[infer_count.*] = if (elems.len > 0) elems[0] else tymod.ID_UNKNOWN;
                                infer_count.* += 1;
                            }
                            return .yes;
                        }
                    }
                }
            }
            // `Promise<infer R>` / `PromiseLike<infer R>` pattern.
            if (std.mem.eql(u8, nm, "Promise") or std.mem.eql(u8, nm, "PromiseLike")) {
                const cht = self.store.get(check_ty);
                if (cht.kind == .type_ref and
                    (std.mem.eql(u8, cht.name, "Promise") or std.mem.eql(u8, cht.name, "PromiseLike")))
                {
                    const first_arg = self.firstTypeArg(n);
                    if (first_arg != .none) {
                        var an = first_arg;
                        while (self.ast_ref.nodeTag(an) == .ts_parenthesized_type) an = self.ast_ref.nodeData(an).lhs;
                        if (self.ast_ref.nodeTag(an) == .ts_infer_type) {
                            const param_node = self.ast_ref.nodeData(an).lhs;
                            if (param_node != .none and infer_count.* < infer_keys.len) {
                                const check_args = self.store.idsOf(cht.list_data);
                                infer_keys[infer_count.*] = self.ast_ref.tokenText(
                                    self.ast_ref.nodeMainToken(param_node));
                                infer_vals[infer_count.*] = if (check_args.len > 0) check_args[0] else tymod.ID_UNKNOWN;
                                infer_count.* += 1;
                            }
                            return .yes;
                        }
                    }
                }
            }
        }

        // Function type `(...) => infer R` — capture the return type.
        if (tag == .ts_function_type or tag == .ts_constructor_type) {
            const cht = self.store.get(check_ty);
            if (cht.kind == .function_t) {
                const d = self.ast_ref.nodeData(n);
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(d.lhs));
                if (fd.body != .none) {
                    var ret_n = fd.body;
                    while (self.ast_ref.nodeTag(ret_n) == .ts_parenthesized_type)
                        ret_n = self.ast_ref.nodeData(ret_n).lhs;
                    if (self.ast_ref.nodeTag(ret_n) == .ts_infer_type) {
                        const param_node = self.ast_ref.nodeData(ret_n).lhs;
                        if (param_node != .none and infer_count.* < infer_keys.len) {
                            const sigs = self.store.signaturesOf(cht.signatures);
                            infer_keys[infer_count.*] = self.ast_ref.tokenText(
                                self.ast_ref.nodeMainToken(param_node));
                            infer_vals[infer_count.*] = if (sigs.len > 0) sigs[0].return_type else tymod.ID_UNKNOWN;
                            infer_count.* += 1;
                        }
                        return .yes;
                    }
                }
            }
        }

        // Tuple `[infer Head, ...infer Tail]` — match against a tuple/array check type.
        if (tag == .ts_tuple_type) {
            const cht = self.store.get(check_ty);
            if (cht.kind == .tuple_t or cht.kind == .array_t) {
                const check_elems = self.store.idsOf(cht.list_data);
                const d = self.ast_ref.nodeData(n);
                const slice = self.directRange(d.lhs, d.rhs) orelse {
                    return .unknown;
                };
                var all_infer = true;
                for (slice, 0..) |raw, ei| {
                    var elem_n: NodeIndex = @enumFromInt(raw);
                    while (self.ast_ref.nodeTag(elem_n) == .ts_parenthesized_type)
                        elem_n = self.ast_ref.nodeData(elem_n).lhs;
                    const elem_tag = self.ast_ref.nodeTag(elem_n);
                    if (elem_tag == .ts_infer_type) {
                        const param_node = self.ast_ref.nodeData(elem_n).lhs;
                        if (param_node != .none and infer_count.* < infer_keys.len) {
                            infer_keys[infer_count.*] = self.ast_ref.tokenText(
                                self.ast_ref.nodeMainToken(param_node));
                            // Bind to check_ty element at same index, or ID_UNKNOWN for rest.
                            infer_vals[infer_count.*] = if (ei < check_elems.len)
                                check_elems[ei]
                            else
                                tymod.ID_UNKNOWN;
                            infer_count.* += 1;
                        }
                    } else {
                        all_infer = false;
                    }
                }
                if (all_infer) return .yes;
            }
        }

        // General case: resolve the extends type with substitution and compare.
        const extends_ty = self.resolveTypeNodeWithSubst(n, keys, vals);
        return self.simpleAssignable(check_ty, extends_ty);
    }

    /// Distribute `T extends U ? A : B` over each member of a union check type.
    fn distributeConditional(
        self: *Checker,
        check_union_ty: TypeId,
        extends_node: NodeIndex,
        true_node: NodeIndex,
        false_node: NodeIndex,
        keys: []const []const u8,
        vals: []const TypeId,
    ) TypeId {
        const check_t = self.store.get(check_union_ty);
        const members = self.store.idsOf(check_t.list_data);
        if (members.len == 0) return tymod.ID_UNKNOWN;

        var result_buf: [16]TypeId = undefined;
        var n_results: usize = 0;

        for (members) |member_ty| {
            if (n_results >= result_buf.len) break;

            var infer_keys_buf: [4][]const u8 = undefined;
            var infer_vals_buf: [4]TypeId = undefined;
            var infer_count: usize = 0;

            const matched = self.matchConditionalExtends(
                member_ty, extends_node, keys, vals,
                &infer_keys_buf, &infer_vals_buf, &infer_count,
            );

            const branch_ty: TypeId = switch (matched) {
                .yes => blk: {
                    if (infer_count == 0) break :blk self.resolveTypeNodeWithSubst(true_node, keys, vals);
                    var mk: [8][]const u8 = undefined;
                    var mv: [8]TypeId = undefined;
                    var nm: usize = 0;
                    for (keys, vals) |k, v| { if (nm >= mk.len) break; mk[nm] = k; mv[nm] = v; nm += 1; }
                    for (infer_keys_buf[0..infer_count], infer_vals_buf[0..infer_count]) |k, v| {
                        if (nm >= mk.len) break; mk[nm] = k; mv[nm] = v; nm += 1;
                    }
                    break :blk self.resolveTypeNodeWithSubst(true_node, mk[0..nm], mv[0..nm]);
                },
                .no => self.resolveTypeNodeWithSubst(false_node, keys, vals),
                .unknown => blk: {
                    // Merge any infer bindings captured during the match before
                    // resolving true_node (mirrors .yes handling above and the
                    // analogous path in resolveConditionalTypeWithSubst).
                    const a = if (infer_count == 0) self.resolveTypeNodeWithSubst(true_node, keys, vals) else a_blk: {
                        var mk: [8][]const u8 = undefined;
                        var mv: [8]TypeId = undefined;
                        var nm: usize = 0;
                        for (keys, vals) |k, v| { if (nm >= mk.len) break; mk[nm] = k; mv[nm] = v; nm += 1; }
                        for (infer_keys_buf[0..infer_count], infer_vals_buf[0..infer_count]) |k, v| {
                            if (nm >= mk.len) break; mk[nm] = k; mv[nm] = v; nm += 1;
                        }
                        break :a_blk self.resolveTypeNodeWithSubst(true_node, mk[0..nm], mv[0..nm]);
                    };
                    const b = self.resolveTypeNodeWithSubst(false_node, keys, vals);
                    if (a.eq(b)) break :blk a;
                    break :blk self.store.unionOf(&.{ a, b }) catch tymod.ID_UNKNOWN;
                },
            };
            result_buf[n_results] = branch_ty;
            n_results += 1;
        }

        if (n_results == 0) return tymod.ID_UNKNOWN;
        if (n_results == 1) return result_buf[0];
        // Collapse `never` members — they arise from exclude-style conditionals.
        var non_never: [16]TypeId = undefined;
        var nn: usize = 0;
        for (result_buf[0..n_results]) |r| {
            if (!r.eq(tymod.ID_NEVER) and nn < non_never.len) {
                non_never[nn] = r;
                nn += 1;
            }
        }
        if (nn == 0) return tymod.ID_NEVER;
        if (nn == 1) return non_never[0];
        return self.store.unionOf(non_never[0..nn]) catch tymod.ID_UNKNOWN;
    }

    /// True when `ty_node` (possibly parenthesized) is a ts_conditional_type.
    fn isConditionalBody(self: *Checker, ty_node: NodeIndex) bool {
        if (ty_node == .none) return false;
        var n = ty_node;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        return self.ast_ref.nodeTag(n) == .ts_conditional_type;
    }

    /// Resolve a conditional type alias by building the substitution map from
    /// the call-site type args and evaluating the body with resolveTypeNodeWithSubst.
    /// Returns null when there are no type params / args, or args don't match.
    fn resolveConditionalAliasWithArgs(
        self: *Checker,
        _: NodeIndex,
        ref_node: NodeIndex,
        ad: ast.TypeAliasData,
    ) ?TypeId {
        if (ad.type_params_end <= ad.type_params) return null;
        const ref_rhs = self.ast_ref.nodeData(ref_node).rhs;
        if (ref_rhs == .none) return null;
        const arg_range = self.ast_ref.extraData(ast.SubRange, @intFromEnum(ref_rhs));
        if (arg_range.end <= arg_range.start) return null;
        var keys_buf: [4][]const u8 = undefined;
        var vals_buf: [4]TypeId = undefined;
        var nsub: usize = 0;
        const tp_count = ad.type_params_end - ad.type_params;
        const arg_count = arg_range.end - arg_range.start;
        const n = @min(@min(tp_count, arg_count), keys_buf.len);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tp: NodeIndex = @enumFromInt(self.ast_ref.extra_data[ad.type_params + i]);
            const arg: NodeIndex = @enumFromInt(self.ast_ref.extra_data[arg_range.start + i]);
            if (self.ast_ref.nodeTag(tp) != .ts_type_parameter) continue;
            keys_buf[nsub] = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp));
            // A free type parameter as the argument (e.g. `Extractor<D>` where D
            // is still generic) keeps a conditional-type alias *deferred* in TS:
            // its check type isn't concrete, so neither branch is chosen. Binding
            // it to the param's *constraint* (what resolveTypeNode does) would
            // evaluate a `branch | never` union that reads as `any` when the
            // constraint is `any`-ish. Mark it type_param so the conditional
            // resolver defers to unknown instead.
            vals_buf[nsub] = if (self.argIsInScopeTypeParam(arg))
                (self.store.add(.{ .kind = .type_param }) catch tymod.ID_UNKNOWN)
            else
                self.resolveTypeNode(arg);
            nsub += 1;
        }
        if (nsub == 0) return null;
        return self.resolveTypeNodeWithSubst(ad.type_node, keys_buf[0..nsub], vals_buf[0..nsub]);
    }

    /// True when the type-position AST node references a name we
    /// can't resolve — type parameter (in scope) or `infer V`.
    fn typeNodeReferencesUnresolved(self: *Checker, node: NodeIndex) bool {
        var n = node;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        const tag = self.ast_ref.nodeTag(n);
        if (tag == .ts_infer_type) return true;
        if (tag == .ts_type_reference) {
            const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
            // Names like `D`, `T`, `V` not in known_type_names and not
            // a built-in are typically type parameters.
            if (!self.known_type_names.contains(name)) {
                // built-in keywords skip — they'd be caught by
                // resolveTypeRef.
                if (std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "unknown") or
                    std.mem.eql(u8, name, "never") or std.mem.eql(u8, name, "string") or
                    std.mem.eql(u8, name, "number") or std.mem.eql(u8, name, "boolean") or
                    std.mem.eql(u8, name, "bigint") or std.mem.eql(u8, name, "symbol") or
                    std.mem.eql(u8, name, "object") or std.mem.eql(u8, name, "void") or
                    std.mem.eql(u8, name, "undefined") or std.mem.eql(u8, name, "null"))
                {
                    return false;
                }
                return true;
            }
        }
        if (tag == .ts_union_type or tag == .ts_intersection_type) {
            const d = self.ast_ref.nodeData(n);
            const s = @intFromEnum(d.lhs);
            const e = @intFromEnum(d.rhs);
            if (e > s and e <= self.ast_ref.extra_data.len) {
                for (self.ast_ref.extra_data[s..e]) |raw| {
                    const m: NodeIndex = @enumFromInt(raw);
                    if (typeNodeReferencesUnresolved(self, m)) return true;
                }
            }
        }
        return false;
    }

    /// Three-valued assignability check for the cases we can decide
    /// without a full TypeScript-style relation algebra.  Returns
    /// `.unknown` when either side is `any`/`unknown` or the
    /// relation depends on machinery we don't implement.
    pub const AssignResult = enum { yes, no, unknown };
    pub fn simpleAssignablePub(self: *Checker, source: TypeId, target: TypeId) AssignResult {
        return self.simpleAssignable(source, target);
    }
    fn simpleAssignable(self: *Checker, source: TypeId, target: TypeId) AssignResult {
        if (source.eq(target)) return .yes;
        if (target.eq(tymod.ID_ANY) or source.eq(tymod.ID_ANY)) return .yes;
        if (target.eq(tymod.ID_UNKNOWN)) return .yes;
        const s = self.store.get(source);
        const t = self.store.get(target);
        // Primitive kind match.
        if (s.kind == t.kind) {
            switch (s.kind) {
                .number, .string, .boolean, .bigint, .symbol,
                .null_t, .undefined_t, .void_t, .object_keyword,
                => return .yes,
                else => {},
            }
        }
        // Literal types assign to their base.
        if (t.kind == .number and s.kind == .number_literal) return .yes;
        if (t.kind == .string and s.kind == .string_literal) return .yes;
        if (t.kind == .boolean and s.kind == .boolean_literal) return .yes;
        if (t.kind == .bigint and s.kind == .bigint_literal) return .yes;
        // Union targets: assignable if assignable to any member.
        if (t.kind == .union_t) {
            var any_unknown = false;
            for (self.store.idsOf(t.list_data)) |m| {
                switch (self.simpleAssignable(source, m)) {
                    .yes => return .yes,
                    .unknown => any_unknown = true,
                    .no => {},
                }
            }
            return if (any_unknown) .unknown else .no;
        }
        // Union sources: assignable if EVERY member is assignable.
        if (s.kind == .union_t) {
            var any_unknown = false;
            for (self.store.idsOf(s.list_data)) |m| {
                switch (self.simpleAssignable(m, target)) {
                    .yes => {},
                    .no => return .no,
                    .unknown => any_unknown = true,
                }
            }
            return if (any_unknown) .unknown else .yes;
        }
        return .unknown;
    }

    /// Three-valued STRUCTURAL assignability — extends simpleAssignable to
    /// objects / arrays / tuples / functions / type-refs, returning `.no` only
    /// for confident mismatches (missing required prop, scalar-primitive clash,
    /// readonly→mutable array, tuple-length / function-arity mismatch) and
    /// `.unknown` for anything that depends on machinery we don't model (a
    /// type_param/generic or error type on either side, named type_ref
    /// mismatches, index/mapped/conditional types, recursion cutoff).  The
    /// facade maps `.unknown` → assignable (FP-safe), so `.no` must be sound.
    pub fn structuralAssignablePub(self: *Checker, source: TypeId, target: TypeId) AssignResult {
        return self.structuralAssignable(source, target, 0);
    }

    fn isScalarPrimKind(k: tymod.TypeKind) bool {
        return switch (k) {
            .number, .string, .boolean, .bigint, .symbol,
            .number_literal, .string_literal, .boolean_literal, .bigint_literal,
            => true,
            else => false,
        };
    }

    /// Property names present on every primitive's apparent (boxed) type — so a
    /// primitive *is* assignable to an object requiring only these.
    fn isApparentMember(name: []const u8) bool {
        return std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "valueOf") or
            std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "constructor") or
            std.mem.eql(u8, name, "hasOwnProperty");
    }

    fn structuralAssignable(self: *Checker, source: TypeId, target: TypeId, depth: u8) AssignResult {
        if (source.eq(target)) return .yes;
        if (target.eq(tymod.ID_ANY) or source.eq(tymod.ID_ANY)) return .yes;
        if (target.eq(tymod.ID_UNKNOWN)) return .yes;
        if (depth > 6) return .unknown; // recursion / cycle guard
        const s = self.store.get(source);
        const t = self.store.get(target);
        if (s.kind == .never) return .yes;
        // `never` is the bottom type: only `never` is assignable to it (source
        // `any`/`never` already returned above), so any other source → no.
        if (t.kind == .never) return .no;
        // `unknown` is the top type: assignable only to `unknown`/`any` (both
        // handled above), so an `unknown` source flowing into any concrete
        // target is NOT assignable (e.g. `unknown as number`, element of
        // `unknown[] as number[]`). Decisive `.no`, not `.unknown`.
        if (s.kind == .unknown) return .no;
        // Error type → can't decide.
        if (s.kind == .error_t or t.kind == .error_t) return .unknown;
        // Target type_param: assignable only if the source IS that variable, or a
        // type parameter whose constraint chain reaches it (`V extends T` → V ⊆ T,
        // so `V as T` is safe). A concrete type — even the constraint — or an
        // unrelated parameter is NOT assignable (`x as T`, `T as V` are unsafe).
        if (t.kind == .type_param) {
            if (s.kind != .type_param) return .no;
            if (std.mem.eql(u8, s.name, t.name)) return .yes; // same parameter
            var cur = source;
            var guard: u8 = 0;
            while (guard < 8) : (guard += 1) {
                const cs = self.store.idsOf(self.store.get(cur).list_data);
                if (cs.len == 0) break;
                const c = cs[0];
                const ct = self.store.get(c);
                if (ct.kind != .type_param) break;
                if (std.mem.eql(u8, ct.name, t.name)) return .yes; // reached target via chain
                if (c.eq(cur)) break;
                cur = c;
            }
            return .no;
        }
        // Source type_param: TS treats a type parameter as a source as assignable
        // exactly when its constraint is — so pass the constraint's result through
        // (`T extends boolean as true` → boolean→true = no → unsafe). An
        // unconstrained T is a fresh type variable assignable only to
        // any/unknown/itself (handled above) → not to any concrete target.
        if (s.kind == .type_param) {
            const cs = self.store.idsOf(s.list_data);
            if (cs.len == 0) return .no; // unconstrained
            return self.structuralAssignable(cs[0], target, depth + 1);
        }
        // Strict-null: `undefined`/`null` are not assignable to a scalar
        // primitive (and vice versa) — `string | undefined as string` narrows
        // unsafely. (`undefined → void` and the eq case are handled above/below.)
        if ((s.kind == .undefined_t or s.kind == .null_t) and isScalarPrimKind(t.kind)) return .no;
        if ((t.kind == .undefined_t or t.kind == .null_t) and isScalarPrimKind(s.kind)) return .no;
        // Union source: EVERY member assignable to target (check before
        // union-target so a union→union compares each source member, not the
        // whole union against each target member).
        if (s.kind == .union_t) {
            var any_unknown = false;
            for (self.store.idsOf(s.list_data)) |m| switch (self.structuralAssignable(m, target, depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            };
            return if (any_unknown) .unknown else .yes;
        }
        // Union target: assignable to ANY member.
        if (t.kind == .union_t) {
            var any_unknown = false;
            for (self.store.idsOf(t.list_data)) |m| switch (self.structuralAssignable(source, m, depth + 1)) {
                .yes => return .yes, .unknown => any_unknown = true, .no => {},
            };
            return if (any_unknown) .unknown else .no;
        }
        // Intersection target: assignable to EVERY member.
        if (t.kind == .intersection_t) {
            var any_unknown = false;
            for (self.store.idsOf(t.list_data)) |m| switch (self.structuralAssignable(source, m, depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            };
            return if (any_unknown) .unknown else .yes;
        }
        // Intersection source: ANY member assignable is enough.
        if (s.kind == .intersection_t) {
            var any_unknown = false;
            for (self.store.idsOf(s.list_data)) |m| switch (self.structuralAssignable(m, target, depth + 1)) {
                .yes => return .yes, .unknown => any_unknown = true, .no => {},
            };
            return if (any_unknown) .unknown else .no;
        }
        // Same-kind primitives.
        if (s.kind == t.kind) switch (s.kind) {
            .number, .string, .boolean, .bigint, .symbol,
            .null_t, .undefined_t, .void_t, .object_keyword,
            => return .yes,
            else => {},
        };
        // Literal → base primitive.
        if (t.kind == .number and s.kind == .number_literal) return .yes;
        if (t.kind == .string and s.kind == .string_literal) return .yes;
        if (t.kind == .boolean and s.kind == .boolean_literal) return .yes;
        if (t.kind == .bigint and s.kind == .bigint_literal) return .yes;
        // Literal → same-value literal (definite yes/no).
        if (s.kind == .number_literal and t.kind == .number_literal)
            return if (s.literal_value.number == t.literal_value.number) .yes else .no;
        if (s.kind == .string_literal and t.kind == .string_literal)
            return if (std.mem.eql(u8, s.literal_value.string, t.literal_value.string)) .yes else .no;
        if (s.kind == .boolean_literal and t.kind == .boolean_literal)
            return if (s.literal_value.boolean == t.literal_value.boolean) .yes else .no;
        if (s.kind == .bigint_literal and t.kind == .bigint_literal)
            return if (std.mem.eql(u8, s.literal_value.bigint, t.literal_value.bigint)) .yes else .no;
        // Structural object: target's every prop present + assignable in source.
        if (s.kind == .object_t and t.kind == .object_t) {
            const s_props = self.store.propsOf(s.object_props);
            var any_unknown = false;
            for (self.store.propsOf(t.object_props)) |tp| {
                var sp_opt: ?tymod.ObjectProp = null;
                for (s_props) |sp| if (std.mem.eql(u8, sp.name, tp.name)) { sp_opt = sp; break; };
                const sp = sp_opt orelse {
                    if (tp.optional) continue;
                    return .no; // missing required prop
                };
                if (sp.optional and !tp.optional) return .no;
                switch (self.structuralAssignable(sp.type_id, tp.type_id, depth + 1)) {
                    .yes => {}, .no => return .no, .unknown => any_unknown = true,
                }
            }
            return if (any_unknown) .unknown else .yes;
        }
        // Scalar primitive → object literal: not assignable when the object
        // requires a "data" property the primitive lacks (`string as { hello:
        // 'world' }`). Skip well-known apparent members (toString/valueOf/length)
        // which a primitive's boxed type does provide — leave those `.unknown`
        // rather than risk a false positive (we don't model apparent types).
        if (isScalarPrimKind(s.kind) and t.kind == .object_t) {
            for (self.store.propsOf(t.object_props)) |tp| {
                if (tp.optional or isApparentMember(tp.name)) continue;
                return .no;
            }
            return .unknown;
        }
        // Array / tuple covariance.
        if ((s.kind == .array_t or s.kind == .readonly_array_t) and
            (t.kind == .array_t or t.kind == .readonly_array_t))
        {
            if (s.kind == .readonly_array_t and t.kind == .array_t) return .no;
            const se = self.store.idsOf(s.list_data);
            const te = self.store.idsOf(t.list_data);
            if (se.len == 0 or te.len == 0) return .unknown;
            return self.structuralAssignable(se[0], te[0], depth + 1);
        }
        if (s.kind == .tuple_t and t.kind == .tuple_t) {
            const se = self.store.idsOf(s.list_data);
            const te = self.store.idsOf(t.list_data);
            if (se.len != te.len) return .no;
            var any_unknown = false;
            for (se, te) |a, bb| switch (self.structuralAssignable(a, bb, depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            };
            return if (any_unknown) .unknown else .yes;
        }
        if (s.kind == .tuple_t and (t.kind == .array_t or t.kind == .readonly_array_t)) {
            const se = self.store.idsOf(s.list_data);
            const te = self.store.idsOf(t.list_data);
            if (te.len == 0) return .unknown;
            var any_unknown = false;
            for (se) |e| switch (self.structuralAssignable(e, te[0], depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            };
            return if (any_unknown) .unknown else .yes;
        }
        // type_ref: different NAMES — can't decide structurally → unknown.
        if (s.kind == .type_ref and t.kind == .type_ref) {
            if (!std.mem.eql(u8, s.name, t.name)) return .unknown;
            const sa = self.store.idsOf(s.list_data);
            const ta = self.store.idsOf(t.list_data);
            if (sa.len != ta.len) return .unknown;
            var any_unknown = false;
            for (sa, ta) |a, bb| switch (self.structuralAssignable(a, bb, depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            };
            return if (any_unknown) .unknown else .yes;
        }
        // The global `Function` type carries no specific call signature, so it
        // is NOT assignable to a concrete function type (`Function as () => void`
        // is unsafe). The reverse — a function value as `Function` — is fine and
        // left to the type_ref path / unknown.
        if (s.kind == .type_ref and std.mem.eql(u8, s.name, "Function") and t.kind == .function_t) return .no;
        // Function variance: arity + param contravariance + return covariance.
        if (s.kind == .function_t and t.kind == .function_t) {
            const s_sigs = self.store.signaturesOf(s.signatures);
            const t_sigs = self.store.signaturesOf(t.signatures);
            if (s_sigs.len == 0 or t_sigs.len == 0) return .unknown;
            const s_params = self.store.signatureParamsOf(s_sigs[0]);
            const t_params = self.store.signatureParamsOf(t_sigs[0]);
            if (t_params.len > s_params.len) return .no;
            var any_unknown = false;
            for (t_params, 0..) |tp, i| switch (self.structuralAssignable(tp, s_params[i], depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            };
            switch (self.structuralAssignable(s_sigs[0].return_type, t_sigs[0].return_type, depth + 1)) {
                .yes => {}, .no => return .no, .unknown => any_unknown = true,
            }
            return if (any_unknown) .unknown else .yes;
        }
        // Two distinct SCALAR primitives (number vs string, boolean vs literal,
        // …) are confidently NOT assignable.  Everything else (object↔primitive,
        // type_ref↔object, null/undefined/void edges) stays unknown → FP-safe.
        if (isScalarPrimKind(s.kind) and isScalarPrimKind(t.kind)) return .no;
        return .unknown;
    }

    /// Evaluate a `ts_indexed_access_type` (`T[K]`) when both sides
    /// are statically resolvable: object types looked up by a string-
    /// literal key, array/tuple types indexed by `number` or a numeric
    /// literal, and unions distribute member-wise.
    fn resolveIndexedAccess(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        if (data.lhs == .none or data.rhs == .none) return tymod.ID_UNKNOWN;
        const obj_ty = self.resolveTypeNode(data.lhs);
        // Collect candidate string keys from the index type.  We accept
        // string literal types directly and unions of them.
        var key_buf: [16][]const u8 = undefined;
        const key_count = self.collectStringLiteralKeys(data.rhs, &key_buf, 0) orelse {
            // Non-string-literal index. On an array/tuple this is a numeric index —
            // the `number` keyword OR a numeric literal (`arr[5]`) OR `arr[i]` —
            // and all resolve to the element type. (Object types with a non-string
            // index aren't modelled → unknown.)
            const ot = self.store.get(obj_ty);
            if (ot.kind == .array_t or ot.kind == .readonly_array_t) {
                const elems = self.store.idsOf(ot.list_data);
                if (elems.len > 0) return elems[0];
            } else if (ot.kind == .tuple_t) {
                const elems = self.store.idsOf(ot.list_data);
                if (elems.len > 0) return self.store.unionOf(elems) catch tymod.ID_UNKNOWN;
            }
            return tymod.ID_UNKNOWN;
        };
        if (key_count == 0) return tymod.ID_UNKNOWN;
        var member_buf: [16]TypeId = undefined;
        var member_n: usize = 0;
        var i: usize = 0;
        while (i < key_count) : (i += 1) {
            const t = self.propertyTypeOfTypeId(obj_ty, key_buf[i]) orelse continue;
            if (member_n < member_buf.len) {
                member_buf[member_n] = t;
                member_n += 1;
            }
        }
        if (member_n == 0) return tymod.ID_UNKNOWN;
        if (member_n == 1) return member_buf[0];
        return self.store.unionOf(member_buf[0..member_n]) catch tymod.ID_UNKNOWN;
    }

    /// Look up `key` in `obj_ty`'s structural shape, walking unions/
    /// intersections.  Returns the prop's TypeId when found.
    fn propertyTypeOfTypeId(self: *Checker, obj_ty: TypeId, key: []const u8) ?TypeId {
        const t = self.store.get(obj_ty);
        if (t.kind == .object_t) {
            for (self.store.propsOf(t.object_props)) |p| {
                if (std.mem.eql(u8, p.name, key)) return p.type_id;
            }
            return null;
        }
        if (t.kind == .union_t or t.kind == .intersection_t) {
            for (self.store.idsOf(t.list_data)) |m| {
                if (self.propertyTypeOfTypeId(m, key)) |r| return r;
            }
        }
        return null;
    }

    const MappedTypeModifiers = struct {
        is_optional: bool,
        remove_optional: bool,
        is_readonly: bool,
        remove_readonly: bool,
    };

    /// Scan the token stream of a `ts_mapped_type` node to extract
    /// `readonly`/`-readonly`/`+?`/`-?` modifiers.
    fn mappedTypeModifiers(self: *Checker, ty_node: NodeIndex) MappedTypeModifiers {
        const start_tok = self.ast_ref.nodeMainToken(ty_node);
        const token_tags = self.ast_ref.tokens.items(.tag);
        var i: usize = @intCast(start_tok);
        var result: MappedTypeModifiers = .{
            .is_optional = false,
            .remove_optional = false,
            .is_readonly = false,
            .remove_readonly = false,
        };
        // Scan from `{` looking for tokens before the first `[`.
        while (i < token_tags.len) : (i += 1) {
            const t = token_tags[i];
            if (t == .l_bracket) break;
            if (t == .kw_readonly) {
                result.is_readonly = true;
            } else if (t == .minus) {
                // `-readonly` — check next token
                if (i + 1 < token_tags.len and token_tags[i + 1] == .kw_readonly) {
                    result.remove_readonly = true;
                    i += 1;
                }
            } else if (t == .plus) {
                // `+readonly` — check next token
                if (i + 1 < token_tags.len and token_tags[i + 1] == .kw_readonly) {
                    result.is_readonly = true;
                    i += 1;
                }
            }
        }
        // Now find the first `]` and check the token after it.
        while (i < token_tags.len) : (i += 1) {
            if (token_tags[i] == .r_bracket) {
                if (i + 1 >= token_tags.len) break;
                const after = token_tags[i + 1];
                if (after == .question) {
                    result.is_optional = true;
                } else if (after == .plus and i + 2 < token_tags.len and token_tags[i + 2] == .question) {
                    result.is_optional = true;
                } else if (after == .minus and i + 2 < token_tags.len and token_tags[i + 2] == .question) {
                    result.remove_optional = true;
                }
                break;
            }
        }
        return result;
    }

    fn resolveMappedType(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        // SubRange layout for ts_mapped_type: [key_param, constraint, as_type, value_type]
        if (slice.len < 4) return tymod.ID_UNKNOWN;
        const constraint: NodeIndex = @enumFromInt(slice[1]);
        const as_type: NodeIndex = @enumFromInt(slice[2]);
        const value_type: NodeIndex = @enumFromInt(slice[3]);
        if (constraint == .none or value_type == .none) return tymod.ID_UNKNOWN;
        // `as` clause: `as never` → empty object; `as Expr` → open sentinel.
        if (as_type != .none) {
            const as_resolved = self.resolveTypeNode(as_type);
            if (as_resolved.eq(tymod.ID_NEVER)) {
                const empty = self.store.appendObjectProps(&.{}) catch return tymod.ID_UNKNOWN;
                return self.store.add(.{ .kind = .object_t, .object_props = empty }) catch tymod.ID_UNKNOWN;
            }
            // Unknown as-expression — fall through with open sentinel.
        }

        const mods = self.mappedTypeModifiers(ty_node);
        const is_optional = mods.is_optional;
        const is_readonly = mods.is_readonly;

        var keys_buf: [16][]const u8 = undefined;
        const key_count_opt = self.collectStringLiteralKeys(constraint, &keys_buf, 0);
        if (key_count_opt == null) {
            // Open constraint (e.g. `Lowercase<string>`) — emit a single "[]" sentinel
            // so callers can detect that any string key maps to the value type.
            const val_ty = self.resolveTypeNode(value_type);
            const prop: tymod.ObjectProp = .{
                .name = "[]",
                .type_id = val_ty,
                .optional = is_optional,
                .readonly = is_readonly,
            };
            const list = self.store.appendObjectProps(&.{prop}) catch return tymod.ID_UNKNOWN;
            return self.store.add(.{ .kind = .object_t, .object_props = list }) catch tymod.ID_UNKNOWN;
        }
        const key_count = key_count_opt.?;
        if (key_count == 0) return tymod.ID_UNKNOWN;

        const val_ty = self.resolveTypeNode(value_type);
        var props_buf: [16]tymod.ObjectProp = undefined;
        var prop_count: usize = 0;
        var i: usize = 0;
        while (i < key_count) : (i += 1) {
            const name = keys_buf[i];
            // TypeScript synthesises mapped-type properties without a real
            // declaration node — TSe's `no-base-to-string` (and similar
            // rules) intentionally treat these as if the default Object
            // method applies, so a mapped `toString` / `toLocaleString` /
            // `valueOf` key does NOT count as user-defined coercion.
            // Skipping the prop keeps `hasUserStringCoercion`-style checks
            // honest while still producing a real object_t for the type.
            if (std.mem.eql(u8, name, "toString") or
                std.mem.eql(u8, name, "toLocaleString") or
                std.mem.eql(u8, name, "valueOf"))
            {
                continue;
            }
            props_buf[prop_count] = .{
                .name = name,
                .type_id = val_ty,
                .optional = is_optional,
                .readonly = is_readonly,
            };
            prop_count += 1;
        }
        const list = self.store.appendObjectProps(props_buf[0..prop_count]) catch return tymod.ID_UNKNOWN;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch tymod.ID_UNKNOWN;
    }

    /// Walk `node` collecting any string-literal type members it
    /// represents.  Handles plain `string_literal`, parenthesised
    /// wrappers, unions of string literals, and aliases that
    /// resolve to the same.  Returns the count written, or null if
    /// any member can't be reduced to a known string key.
    fn collectStringLiteralKeys(
        self: *Checker,
        node: NodeIndex,
        out: *[16][]const u8,
        start: usize,
    ) ?usize {
        var n = node;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        const tag = self.ast_ref.nodeTag(n);
        if (tag == .string_literal) {
            if (start >= out.len) return null;
            const tok = self.ast_ref.nodeMainToken(n);
            const raw = self.ast_ref.tokenText(tok);
            const name = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            out[start] = name;
            return start + 1;
        }
        // TS parses `'foo'` in type position as ts_type_reference whose
        // main_token is the quoted literal text — peel the quotes.
        if (tag == .ts_type_reference) {
            const tok = self.ast_ref.nodeMainToken(n);
            const raw = self.ast_ref.tokenText(tok);
            if (raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"' or raw[0] == '`')) {
                if (start >= out.len) return null;
                out[start] = raw[1 .. raw.len - 1];
                return start + 1;
            }
            const name = raw;
            if (self.type_decl_nodes.get(name)) |decl| {
                if (self.ast_ref.nodeTag(decl) == .ts_type_alias_decl) {
                    const dd = self.ast_ref.nodeData(decl);
                    const ad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(dd.lhs));
                    return self.collectStringLiteralKeys(ad.type_node, out, start);
                }
                return null;
            }
            // Type parameter — descend into its constraint expression.
            if (self.findTypeParameterDecl(n, name)) |tp_decl| {
                const tp_data = self.ast_ref.nodeData(tp_decl);
                if (tp_data.lhs == .none) return null;
                return self.collectStringLiteralKeys(tp_data.lhs, out, start);
            }
            return null;
        }
        if (tag == .ts_union_type) {
            const d = self.ast_ref.nodeData(n);
            const members = self.directRange(d.lhs, d.rhs) orelse return null;
            var pos = start;
            for (members) |raw_idx| {
                const member: NodeIndex = @enumFromInt(raw_idx);
                pos = self.collectStringLiteralKeys(member, out, pos) orelse return null;
            }
            return pos;
        }
        if (tag == .identifier) {
            const tok = self.ast_ref.nodeMainToken(n);
            const name = self.ast_ref.tokenText(tok);
            const decl = self.type_decl_nodes.get(name) orelse return null;
            if (self.ast_ref.nodeTag(decl) != .ts_type_alias_decl) return null;
            const dd = self.ast_ref.nodeData(decl);
            const ad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(dd.lhs));
            return self.collectStringLiteralKeys(ad.type_node, out, start);
        }
        return null;
    }

    /// Walk the AST once and collect names declared as types.  Sources:
    ///   * ts_type_alias_decl, ts_interface_decl, ts_enum_decl
    ///   * class_decl (also acts as a type name)
    ///   * ts_namespace_decl, ts_module_decl
    ///   * import_specifier / import_default_specifier / import_namespace_specifier
    ///   * ts_type_parameter (generic params)
    /// We also pre-populate built-in lib type names so common imports
    /// like `Date`, `Map`, `Promise<T>` don't get classified as errors.
    /// True when an enum member's initializer is string-valued.  Handles
    /// direct string/template literals and call/member expressions
    /// whose source includes a string literal hint.
    fn enumMemberKindIsString(self: *Checker, init_node: NodeIndex) bool {
        var n = init_node;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        const t = self.ast_ref.nodeTag(n);
        if (t == .string_literal) return true;
        if (t == .template_literal) {
            // Template without substitutions is string; with substitutions
            // we can't tell — fall through.
            return true;
        }
        // Cross-enum reference: First.A where First is a string enum.
        if (t == .member_expr or t == .optional_member_expr) {
            const md = self.ast_ref.nodeData(n);
            if (md.lhs != .none and self.ast_ref.nodeTag(md.lhs) == .identifier) {
                const obj_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.lhs));
                if (self.enum_kinds.get(obj_name)) |k| return k == .string;
            }
        }
        // Function call returning string — resolve via type checker.
        const ty = self.typeOf(n);
        const tt = self.store.get(ty);
        if (tt.kind == .string or tt.kind == .string_literal) return true;
        return false;
    }

    fn enumMemberKindIsNumber(self: *Checker, init_node: NodeIndex) bool {
        var n = init_node;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        const t = self.ast_ref.nodeTag(n);
        if (t == .number_literal or t == .bigint_literal) return true;
        if (t == .unary_minus or t == .unary_plus) {
            return self.enumMemberKindIsNumber(self.ast_ref.nodeData(n).lhs);
        }
        if (t == .member_expr or t == .optional_member_expr) {
            const md = self.ast_ref.nodeData(n);
            if (md.lhs != .none and self.ast_ref.nodeTag(md.lhs) == .identifier) {
                const obj_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.lhs));
                if (self.enum_kinds.get(obj_name)) |k| return k == .number;
            }
        }
        const ty = self.typeOf(n);
        const tt = self.store.get(ty);
        if (tt.kind == .number or tt.kind == .number_literal or
            tt.kind == .bigint or tt.kind == .bigint_literal) return true;
        return false;
    }

    pub fn enumKindOf(self: *const Checker, name: []const u8) ?EnumKind {
        return self.enum_kinds.get(name);
    }

    /// Populate `global_value_types` with structural shapes for the
    /// well-known JS globals that lint rules care about.  This is a
    /// hand-curated subset of TSC's lib.es5/lib.dom — enough to type
    /// `console.log()` as `void`, `JSON.parse()` as `any`,
    /// `Math.random()` as `number`, etc.  Expand as rules need more.
    fn buildGlobalValueTypes(self: *Checker) !void {
        // ── helpers ───────────────────────────────────────────
        const Helper = struct {
            checker: *Checker,
            fn fnType(h: @This(), ret: TypeId) !TypeId {
                const sig = tymod.Signature{
                    .params_start = 0,
                    .params_end = 0,
                    .return_type = ret,
                };
                return try h.checker.store.functionType(sig);
            }
            fn fnTypeWithParams(h: @This(), params: []const TypeId, ret: TypeId) !TypeId {
                const pr = try h.checker.store.appendSignatureParams(params, &.{});
                const sig = tymod.Signature{
                    .params_start = pr.start,
                    .params_end = pr.end,
                    .return_type = ret,
                };
                return try h.checker.store.functionType(sig);
            }
            // (...data: any[]) => ret  — a single rest param named "data"
            fn fnTypeRestAnyArray(h: @This(), ret: TypeId) !TypeId {
                const any_arr = try h.checker.store.arrayOf(tymod.ID_ANY);
                const name: []const u8 = "data";
                const pr = try h.checker.store.appendSignatureParams(&.{any_arr}, &.{name});
                const sig = tymod.Signature{
                    .params_start = pr.start,
                    .params_end = pr.end,
                    .rest_param_index = 0,
                    .return_type = ret,
                };
                return try h.checker.store.functionType(sig);
            }
            fn objType(h: @This(), props: []const tymod.ObjectProp) !TypeId {
                const list = try h.checker.store.appendObjectProps(props);
                return try h.checker.store.add(.{ .kind = .object_t, .object_props = list });
            }
        };
        const h = Helper{ .checker = self };

        // The global `Promise` value is the PromiseConstructor — its symbol name
        // is what @typescript-eslint's isPromiseConstructorLike (isBuiltinSymbolLike
        // 'PromiseConstructor') checks (prefer-promise-reject-errors:
        // `Promise.reject(nonError)`). Modelled as a named type_ref so the facade
        // surfaces getSymbol().getName() === "PromiseConstructor".
        try self.global_value_types.put(self.gpa, "Promise", try self.store.typeRef("PromiseConstructor", &.{}));

        // Console — methods with ...data: any[] rest param return void; others () => void.
        const void_fn = try h.fnType(tymod.ID_VOID);
        const rest_void_fn = try h.fnTypeRestAnyArray(tymod.ID_VOID);
        const console_methods_rest = [_][]const u8{
            "log", "error", "warn", "info", "debug", "trace",
            "dir", "dirxml", "table",
        };
        const console_methods_void = [_][]const u8{
            "group", "groupEnd", "groupCollapsed",
            "time", "timeEnd", "timeLog",
            "count", "countReset", "clear", "assert", "profile",
            "profileEnd", "timeStamp",
        };
        const console_method_count = console_methods_rest.len + console_methods_void.len;
        var console_props: [console_method_count]tymod.ObjectProp = undefined;
        for (console_methods_rest, 0..) |name, i| {
            console_props[i] = .{ .name = name, .type_id = rest_void_fn };
        }
        for (console_methods_void, 0..) |name, i| {
            console_props[console_methods_rest.len + i] = .{ .name = name, .type_id = void_fn };
        }
        const console_ty = try h.objType(&console_props);
        try self.global_value_types.put(self.gpa, "__console_struct", console_ty);
        try self.global_value_types.put(self.gpa, "console", console_ty);
        try self.natively_bound_type_ids.put(self.gpa, console_ty, {});

        // Math — selection of common methods returning number.
        // (number) => number — single-arg methods. Unnamed param so user-code
        // enrichment can supply the actual param name via the intern mechanism.
        const num_x_fn = try h.fnTypeWithParams(&.{tymod.ID_NUMBER}, tymod.ID_NUMBER);
        // (number, number) => number — two-arg methods.
        const num_xy_fn = try h.fnTypeWithParams(&.{ tymod.ID_NUMBER, tymod.ID_NUMBER }, tymod.ID_NUMBER);
        // (...number[]) => number — variadic methods (min, max, hypot).
        const num_rest_fn = blk: {
            const num_arr = try self.store.arrayOf(tymod.ID_NUMBER);
            const pr = try self.store.appendSignatureParams(&.{num_arr}, &.{});
            const sig: tymod.Signature = .{ .params_start = pr.start, .params_end = pr.end, .rest_param_index = 0, .return_type = tymod.ID_NUMBER };
            break :blk try self.store.functionType(sig);
        };
        // () => number — random.
        const num_fn = try h.fnType(tymod.ID_NUMBER);
        const math_1arg = [_][]const u8{
            "floor", "ceil", "round", "trunc", "abs",
            "sign", "sqrt", "cbrt", "exp", "log", "log2", "log10",
            "log1p", "expm1", "sin", "cos", "tan", "asin", "acos",
            "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
            "fround", "clz32",
        };
        const math_2arg = [_][]const u8{ "pow", "atan2", "imul" };
        const math_variadic = [_][]const u8{ "min", "max", "hypot" };
        var math_props_buf: [math_1arg.len + math_2arg.len + math_variadic.len + 10]tymod.ObjectProp = undefined;
        var math_n: usize = 0;
        for (math_1arg) |name| {
            math_props_buf[math_n] = .{ .name = name, .type_id = num_x_fn, .is_method = true };
            math_n += 1;
        }
        for (math_2arg) |name| {
            math_props_buf[math_n] = .{ .name = name, .type_id = num_xy_fn, .is_method = true };
            math_n += 1;
        }
        for (math_variadic) |name| {
            math_props_buf[math_n] = .{ .name = name, .type_id = num_rest_fn, .is_method = true };
            math_n += 1;
        }
        math_props_buf[math_n] = .{ .name = "random", .type_id = num_fn, .is_method = true };
        math_n += 1;
        // Math constants — number-typed.
        const math_constants = [_][]const u8{ "E", "LN10", "LN2", "LOG10E", "LOG2E", "PI", "SQRT1_2", "SQRT2" };
        for (math_constants) |name| {
            math_props_buf[math_n] = .{ .name = name, .type_id = tymod.ID_NUMBER };
            math_n += 1;
        }
        const math_ty = try h.objType(math_props_buf[0..math_n]);
        try self.global_value_types.put(self.gpa, "__Math_struct", math_ty);
        try self.global_value_types.put(self.gpa, "Math", math_ty);
        try self.natively_bound_type_ids.put(self.gpa, math_ty, {});

        // JSON — parse: any, stringify: string.
        const any_fn = try h.fnType(tymod.ID_ANY);
        const str_fn = try h.fnType(tymod.ID_STRING);
        const json_props = [_]tymod.ObjectProp{
            .{ .name = "parse", .type_id = any_fn },
            .{ .name = "stringify", .type_id = str_fn },
        };
        const json_ty = try h.objType(&json_props);
        try self.global_value_types.put(self.gpa, "__JSON_struct", json_ty);
        try self.global_value_types.put(self.gpa, "JSON", json_ty);
        try self.natively_bound_type_ids.put(self.gpa, json_ty, {});

        // Number — global constructor + utilities; calling it returns number.
        const number_props = [_]tymod.ObjectProp{
            .{ .name = "isFinite", .type_id = try h.fnType(tymod.ID_BOOLEAN) },
            .{ .name = "isInteger", .type_id = try h.fnType(tymod.ID_BOOLEAN) },
            .{ .name = "isNaN", .type_id = try h.fnType(tymod.ID_BOOLEAN) },
            .{ .name = "isSafeInteger", .type_id = try h.fnType(tymod.ID_BOOLEAN) },
            .{ .name = "parseFloat", .type_id = try h.fnType(tymod.ID_NUMBER) },
            .{ .name = "parseInt", .type_id = try h.fnType(tymod.ID_NUMBER) },
            .{ .name = "EPSILON", .type_id = tymod.ID_NUMBER },
            .{ .name = "MAX_SAFE_INTEGER", .type_id = tymod.ID_NUMBER },
            .{ .name = "MIN_SAFE_INTEGER", .type_id = tymod.ID_NUMBER },
            .{ .name = "MAX_VALUE", .type_id = tymod.ID_NUMBER },
            .{ .name = "MIN_VALUE", .type_id = tymod.ID_NUMBER },
            .{ .name = "NaN", .type_id = tymod.ID_NUMBER },
            .{ .name = "NEGATIVE_INFINITY", .type_id = tymod.ID_NUMBER },
            .{ .name = "POSITIVE_INFINITY", .type_id = tymod.ID_NUMBER },
        };
        // The global Number is also callable: `Number(x)` → number.
        const number_callable = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_NUMBER);
        // Stash it on `Number` itself via the same TypeId — at the
        // value site we look up `Number` and read its .signatures when
        // present.  For simplicity expose Number as the function type
        // and attach static methods via a parallel namespace name.
        try self.global_value_types.put(self.gpa, "Number", number_callable);
        const number_static_ty = try h.objType(&number_props);
        // (No standard way to merge call sigs + props yet — rules that
        // need both go through `Number.isFinite` lookups: register the
        // namespace under a second key the member-access path can use.)
        try self.global_value_types.put(self.gpa, "__Number_static", number_static_ty);

        // String — global constructor returning string.
        try self.global_value_types.put(self.gpa, "String", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_STRING));
        // Boolean — global constructor returning boolean.
        try self.global_value_types.put(self.gpa, "Boolean", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BOOLEAN));
        // BigInt — global function returning bigint (`BigInt(1) + 1n` is bigint+
        // bigint, valid for restrict-plus-operands).
        try self.global_value_types.put(self.gpa, "BigInt", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BIGINT));
        // parseInt / parseFloat / isNaN / isFinite — global functions.
        try self.global_value_types.put(self.gpa, "parseInt", try h.fnTypeWithParams(&.{tymod.ID_STRING}, tymod.ID_NUMBER));
        try self.global_value_types.put(self.gpa, "parseFloat", try h.fnTypeWithParams(&.{tymod.ID_STRING}, tymod.ID_NUMBER));
        try self.global_value_types.put(self.gpa, "isNaN", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BOOLEAN));
        try self.global_value_types.put(self.gpa, "isFinite", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BOOLEAN));
        // `void`-like literals exposed as values.
        try self.global_value_types.put(self.gpa, "undefined", tymod.ID_UNDEFINED);
        try self.global_value_types.put(self.gpa, "NaN", tymod.ID_NUMBER);
        try self.global_value_types.put(self.gpa, "Infinity", tymod.ID_NUMBER);

        // Process / globalThis — keep as `any` so member access on
        // `process.cwd()` doesn't trip strict rules but doesn't
        // hallucinate types we haven't modelled.
        try self.global_value_types.put(self.gpa, "process", tymod.ID_ANY);
        try self.global_value_types.put(self.gpa, "globalThis", tymod.ID_ANY);
        // Window — minimal shape with alert / prompt / confirm.  On the global
        // `window`, these resolve to the ambient bound functions (lib.dom's
        // `declare function alert`), so extracting them off `window` is *not*
        // unbound-unsafe — typescript-eslint's unbound-method treats
        // `const { alert } = window` / `window.blur` as valid.  Hence window is
        // registered natively-bound (its members demote to safe fields).
        const window_alert_fn = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_VOID);
        const window_props = [_]tymod.ObjectProp{
            .{ .name = "alert", .type_id = window_alert_fn, .is_method = true },
            .{ .name = "prompt", .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_STRING), .is_method = true },
            .{ .name = "confirm", .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BOOLEAN), .is_method = true },
        };
        const window_ty = try h.objType(&window_props);
        try self.global_value_types.put(self.gpa, "window", window_ty);
        try self.natively_bound_type_ids.put(self.gpa, window_ty, {});
        try self.global_value_types.put(self.gpa, "document", tymod.ID_ANY);
        try self.global_value_types.put(self.gpa, "self", tymod.ID_ANY);

        // Error constructors — callable, return any so `new Error()` is accepted
        // by prefer-promise-reject-errors without forcing us to model Error instances.
        const error_fn = try h.fnTypeWithParams(&.{tymod.ID_STRING}, tymod.ID_ANY);
        for ([_][]const u8{
            "Error", "TypeError", "RangeError", "SyntaxError",
            "ReferenceError", "URIError", "EvalError", "AggregateError",
        }) |ename| {
            try self.global_value_types.put(self.gpa, ename, error_fn);
        }

        // Object — static namespace with commonly-needed methods.
        const object_props = [_]tymod.ObjectProp{
            .{ .name = "keys",                     .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "values",                   .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "entries",                  .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "assign",                   .type_id = try h.fnType(tymod.ID_ANY) },
            .{ .name = "freeze",                   .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "isFrozen",                 .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BOOLEAN) },
            .{ .name = "create",                   .type_id = try h.fnType(tymod.ID_ANY) },
            .{ .name = "getPrototypeOf",           .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "setPrototypeOf",           .type_id = try h.fnType(tymod.ID_ANY) },
            .{ .name = "defineProperty",           .type_id = try h.fnType(tymod.ID_ANY) },
            .{ .name = "getOwnPropertyNames",      .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "getOwnPropertyDescriptor", .type_id = try h.fnType(tymod.ID_ANY) },
            .{ .name = "hasOwn",                   .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY, tymod.ID_STRING}, tymod.ID_BOOLEAN) },
            .{ .name = "fromEntries",              .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "is",                       .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY, tymod.ID_ANY}, tymod.ID_BOOLEAN) },
        };
        const object_ty = try h.objType(&object_props);
        try self.global_value_types.put(self.gpa, "__Object_struct", object_ty);
        try self.global_value_types.put(self.gpa, "Object", object_ty);
        try self.natively_bound_type_ids.put(self.gpa, object_ty, {});

        // Array — static namespace (instance methods resolved per-expression).
        const array_props = [_]tymod.ObjectProp{
            .{ .name = "isArray", .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_BOOLEAN) },
            .{ .name = "from",    .type_id = try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY) },
            .{ .name = "of",      .type_id = try h.fnType(tymod.ID_ANY) },
        };
        const array_ty = try h.objType(&array_props);
        try self.global_value_types.put(self.gpa, "__Array_struct", array_ty);
        try self.global_value_types.put(self.gpa, "Array", array_ty);
        try self.natively_bound_type_ids.put(self.gpa, array_ty, {});

        // Collection constructors — named type refs so isBuiltinSymbolLike works.
        try self.global_value_types.put(self.gpa, "Map",     try self.store.typeRef("MapConstructor",     &.{}));
        try self.global_value_types.put(self.gpa, "Set",     try self.store.typeRef("SetConstructor",     &.{}));
        try self.global_value_types.put(self.gpa, "WeakMap", try self.store.typeRef("WeakMapConstructor", &.{}));
        try self.global_value_types.put(self.gpa, "WeakSet", try self.store.typeRef("WeakSetConstructor", &.{}));
        try self.global_value_types.put(self.gpa, "WeakRef", try self.store.typeRef("WeakRefConstructor", &.{}));
        try self.global_value_types.put(self.gpa, "FinalizationRegistry", try self.store.typeRef("FinalizationRegistry", &.{}));
        try self.global_value_types.put(self.gpa, "Symbol",  try self.store.typeRef("SymbolConstructor",  &.{}));
        try self.global_value_types.put(self.gpa, "Proxy",   try self.store.typeRef("ProxyConstructor",   &.{}));
        try self.global_value_types.put(self.gpa, "Reflect", try self.store.typeRef("Reflect",             &.{}));
        try self.global_value_types.put(self.gpa, "Date",    try self.store.typeRef("DateConstructor",    &.{}));
        try self.global_value_types.put(self.gpa, "RegExp",  try self.store.typeRef("RegExpConstructor",  &.{}));
        try self.global_value_types.put(self.gpa, "URL",     try self.store.typeRef("URLConstructor",     &.{}));
        try self.global_value_types.put(self.gpa, "URLSearchParams",     try self.store.typeRef("URLSearchParamsConstructor", &.{}));
        try self.global_value_types.put(self.gpa, "AbortController",     try self.store.typeRef("AbortController",            &.{}));
        try self.global_value_types.put(self.gpa, "AbortSignal",         try self.store.typeRef("AbortSignal",                &.{}));
        try self.global_value_types.put(self.gpa, "TextEncoder",         try self.store.typeRef("TextEncoder",                &.{}));
        try self.global_value_types.put(self.gpa, "TextDecoder",         try self.store.typeRef("TextDecoder",                &.{}));
        try self.global_value_types.put(self.gpa, "SharedArrayBuffer",   try self.store.typeRef("SharedArrayBuffer",          &.{}));
        try self.global_value_types.put(self.gpa, "Atomics",             try self.store.typeRef("Atomics",                    &.{}));
        try self.global_value_types.put(self.gpa, "Buffer",              try self.store.typeRef("BufferConstructor",          &.{}));

        // Timer functions.
        try self.global_value_types.put(self.gpa, "setTimeout",            try h.fnTypeWithParams(&.{tymod.ID_ANY, tymod.ID_NUMBER}, tymod.ID_NUMBER));
        try self.global_value_types.put(self.gpa, "setInterval",           try h.fnTypeWithParams(&.{tymod.ID_ANY, tymod.ID_NUMBER}, tymod.ID_NUMBER));
        try self.global_value_types.put(self.gpa, "clearTimeout",          try h.fnTypeWithParams(&.{tymod.ID_NUMBER}, tymod.ID_VOID));
        try self.global_value_types.put(self.gpa, "clearInterval",         try h.fnTypeWithParams(&.{tymod.ID_NUMBER}, tymod.ID_VOID));
        try self.global_value_types.put(self.gpa, "queueMicrotask",        try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_VOID));
        try self.global_value_types.put(self.gpa, "setImmediate",          try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_NUMBER));
        try self.global_value_types.put(self.gpa, "clearImmediate",        try h.fnTypeWithParams(&.{tymod.ID_NUMBER}, tymod.ID_VOID));
        try self.global_value_types.put(self.gpa, "requestAnimationFrame", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_NUMBER));
        try self.global_value_types.put(self.gpa, "cancelAnimationFrame",  try h.fnTypeWithParams(&.{tymod.ID_NUMBER}, tymod.ID_VOID));

        // Fetch API — returns any (Promise<Response> approximated as any for now).
        try self.global_value_types.put(self.gpa, "fetch", try h.fnTypeWithParams(&.{tymod.ID_ANY, tymod.ID_ANY}, tymod.ID_ANY));

        // URI encoding / decoding.
        try self.global_value_types.put(self.gpa, "encodeURIComponent", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_STRING));
        try self.global_value_types.put(self.gpa, "decodeURIComponent", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_STRING));
        try self.global_value_types.put(self.gpa, "encodeURI",          try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_STRING));
        try self.global_value_types.put(self.gpa, "decodeURI",          try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_STRING));

        // Base64.
        try self.global_value_types.put(self.gpa, "atob", try h.fnTypeWithParams(&.{tymod.ID_STRING}, tymod.ID_STRING));
        try self.global_value_types.put(self.gpa, "btoa", try h.fnTypeWithParams(&.{tymod.ID_STRING}, tymod.ID_STRING));

        // Miscellaneous.
        try self.global_value_types.put(self.gpa, "structuredClone", try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY));
        try self.global_value_types.put(self.gpa, "eval",             try h.fnTypeWithParams(&.{tymod.ID_ANY}, tymod.ID_ANY));

        // Node.js globals.
        try self.global_value_types.put(self.gpa, "__dirname",  tymod.ID_STRING);
        try self.global_value_types.put(self.gpa, "__filename", tymod.ID_STRING);
        try self.global_value_types.put(self.gpa, "require",    try h.fnTypeWithParams(&.{tymod.ID_STRING}, tymod.ID_ANY));
        try self.global_value_types.put(self.gpa, "module",     tymod.ID_ANY);
        try self.global_value_types.put(self.gpa, "exports",    tymod.ID_ANY);
    }

    /// Append `node` to the value-declaration index under `name`.
    fn appendValueDecl(self: *Checker, name: []const u8, node: NodeIndex) !void {
        const gop = try self.value_decl_by_name.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.gpa, node);
    }

    fn buildKnownTypeNames(self: *Checker) !void {
        const lib_types = [_][]const u8{
            "Array", "ReadonlyArray", "Promise", "Map", "Set", "WeakMap", "WeakSet",
            "Date", "RegExp", "Error", "TypeError", "RangeError", "SyntaxError",
            "ReferenceError", "URIError", "EvalError", "AggregateError",
            "Function", "Object", "Symbol", "BigInt", "JSON", "Math",
            // Wrapper-object types for primitives — type-annotation
            // positions like `foo: Number` should resolve to a
            // `type_ref` named after the wrapper rather than the
            // `error_t` fallback that would suppress rule analysis.
            "Number", "String", "Boolean",
            "ArrayBuffer", "DataView", "Int8Array", "Uint8Array", "Uint8ClampedArray",
            "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
            "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
            "Iterable", "AsyncIterable", "IterableIterator", "AsyncIterator",
            "Iterator", "Generator", "AsyncGenerator", "AsyncIterableIterator",
            "Record", "Partial", "Required", "Readonly", "Pick", "Omit",
            "Exclude", "Extract", "Parameters", "ReturnType",
            "ConstructorParameters", "InstanceType", "NonNullable", "Awaited",
            "ThisType", "NoInfer", "ThisParameterType", "OmitThisParameter",
            "Uppercase", "Lowercase", "Capitalize", "Uncapitalize",
            "ArrayLike", "PropertyKey", "PropertyDescriptor", "PropertyDescriptorMap",
            "TemplateStringsArray", "Buffer", "URL", "URLSearchParams",
            "Element", "HTMLElement", "Node", "Event", "Window", "Document",
            "console", "process",
            "WeakRef", "FinalizationRegistry",
            "AbortController", "AbortSignal",
            "TextEncoder", "TextDecoder",
            "SharedArrayBuffer", "Atomics", "Reflect",
        };
        for (lib_types) |name| try self.known_type_names.put(self.gpa, name, {});

        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const ni: NodeIndex = @enumFromInt(i);
            const tag = self.ast_ref.nodeTag(ni);
            const data = self.ast_ref.nodeData(ni);
            switch (tag) {
                .ts_type_alias_decl => {
                    const ad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(data.lhs));
                    const name = self.ast_ref.tokenText(ad.name);
                    try self.known_type_names.put(self.gpa, name, {});
                    try self.type_decl_nodes.put(self.gpa, name, ni);
                },
                .ts_interface_decl => {
                    const id = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(data.lhs));
                    const name = self.ast_ref.tokenText(id.name);
                    try self.known_type_names.put(self.gpa, name, {});
                    const gop = try self.type_decl_nodes.getOrPut(self.gpa, name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = ni;
                    } else {
                        // Declaration merging: store extra declaration for later.
                        try self.merged_iface_extra.append(self.gpa, .{ .name = name, .node = ni });
                    }
                },
                .ts_enum_decl => {
                    const ed = self.ast_ref.extraData(ast.EnumData, @intFromEnum(data.lhs));
                    const enum_name = self.ast_ref.tokenText(ed.name);
                    try self.known_type_names.put(self.gpa, enum_name, {});
                    try self.type_decl_nodes.put(self.gpa, enum_name, ni);
                    // Determine the ESTABLISHED member kind: the kind of
                    // the FIRST member with a concrete value (string or
                    // number).  This is the rule's "established" kind:
                    // subsequent mismatches fire.  Decl merging: only set
                    // if no prior decl with the same name already set it.
                    if (self.enum_kinds.get(enum_name) == null) {
                        var saw_number = false;
                        var saw_string = false;
                        if (ed.members_start < ed.members_end and ed.members_end <= self.ast_ref.extra_data.len) {
                            for (self.ast_ref.extra_data[ed.members_start..ed.members_end]) |raw| {
                                const m: NodeIndex = @enumFromInt(raw);
                                if (self.ast_ref.nodeTag(m) != .ts_enum_member) continue;
                                const md = self.ast_ref.nodeData(m);
                                if (md.rhs == .none) {
                                    saw_number = true; // auto-increment is numeric
                                    continue;
                                }
                                if (self.enumMemberKindIsString(md.rhs)) { saw_string = true; continue; }
                                if (self.enumMemberKindIsNumber(md.rhs)) { saw_number = true; continue; }
                            }
                        }
                        const kind: ?EnumKind = if (saw_string and saw_number) .mixed
                            else if (saw_string) .string
                            else if (saw_number) .number
                            else null;
                        if (kind) |k| try self.enum_kinds.put(self.gpa, enum_name, k);
                    }
                },
                .class_decl => {
                    const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(data.lhs));
                    if (cd.name != .none) {
                        const tok = self.ast_ref.nodeMainToken(cd.name);
                        const name = self.ast_ref.tokenText(tok);
                        try self.known_type_names.put(self.gpa, name, {});
                        const gop = try self.type_decl_nodes.getOrPut(self.gpa, name);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = ni;
                        } else {
                            // If a same-named interface was registered first, rescue it
                            // into merged_iface_extra so buildClassInstanceType can merge it.
                            if (self.ast_ref.nodeTag(gop.value_ptr.*) == .ts_interface_decl) {
                                try self.merged_iface_extra.append(self.gpa, .{ .name = name, .node = gop.value_ptr.* });
                            }
                            gop.value_ptr.* = ni;
                        }
                    }
                },
                .ts_namespace_decl, .ts_module_decl => {
                    if (data.lhs != .none and data.rhs != .none) {
                        const tok = self.ast_ref.nodeMainToken(data.lhs);
                        const ns_name = self.ast_ref.tokenText(tok);
                        try self.known_type_names.put(self.gpa, ns_name, {});
                        const gop = try self.type_decl_nodes.getOrPut(self.gpa, ns_name);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = ni;
                        } else {
                            try self.merged_ns_extra.append(self.gpa, .{ .name = ns_name, .node = ni });
                        }
                    } else if (data.lhs != .none) {
                        const tok = self.ast_ref.nodeMainToken(data.lhs);
                        try self.known_type_names.put(self.gpa, self.ast_ref.tokenText(tok), {});
                    }
                },
                .ts_type_parameter => {
                    const tok = self.ast_ref.nodeMainToken(ni);
                    try self.known_type_names.put(self.gpa, self.ast_ref.tokenText(tok), {});
                    try self.type_param_nodes.append(self.gpa, ni);
                },
                .declarator => {
                    if (data.lhs != .none and self.ast_ref.nodeTag(data.lhs) == .identifier) {
                        try self.appendValueDecl(self.ast_ref.tokenText(self.ast_ref.nodeMainToken(data.lhs)), ni);
                    }
                },
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .ts_declare_function => {
                    if (data.lhs != .none) {
                        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
                        if (fd.name != .none) {
                            try self.appendValueDecl(self.ast_ref.tokenText(self.ast_ref.nodeMainToken(fd.name)), ni);
                        }
                    }
                },
                .import_decl => {
                    // TS import-equals (`import mod = require("./m")`): the
                    // parser stores no ImportData (lhs == .none); the local
                    // binding is the token after `import` and tsc types it
                    // `typeof mod` — same as a namespace import.
                    if (data.lhs == .none) {
                        if (data.rhs != .none and self.ast_ref.nodeTag(data.rhs) == .call_expr) {
                            const local_tok = self.ast_ref.nodeMainToken(ni) + 1;
                            if (local_tok < self.ast_ref.tokens.len) {
                                const local_name = self.ast_ref.tokenText(local_tok);
                                if (local_name.len > 0) {
                                    // require("spec") argument, if a string literal.
                                    var spec: []const u8 = "";
                                    const cd2 = self.ast_ref.nodeData(data.rhs);
                                    if (cd2.rhs != .none) {
                                        const args = self.directRange(cd2.rhs, cd2.rhs);
                                        _ = args;
                                    }
                                    // The call's first argument is the lone
                                    // string_literal child created before it.
                                    const arg_node: NodeIndex = @enumFromInt(data.rhs.toInt() - 1);
                                    if (self.ast_ref.nodeTag(arg_node) == .string_literal) {
                                        const raw_arg = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(arg_node));
                                        if (raw_arg.len >= 2 and (raw_arg[0] == '\'' or raw_arg[0] == '"'))
                                            spec = raw_arg[1 .. raw_arg.len - 1];
                                    }
                                    try self.known_type_names.put(self.gpa, local_name, {});
                                    try self.namespace_import_map.put(self.gpa, local_name, spec);
                                }
                            }
                        }
                        continue;
                    }
                    const idata = self.ast_ref.extraData(ast.ImportData, @intFromEnum(data.lhs));
                    // Get unquoted module specifier from the string_literal source node.
                    const raw_module = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(idata.source));
                    const module_spec: []const u8 = if (raw_module.len >= 2 and
                        (raw_module[0] == '\'' or raw_module[0] == '"'))
                        raw_module[1 .. raw_module.len - 1]
                    else
                        raw_module;
                    if (idata.specifiers_end > idata.specifiers_start) {
                        for (self.ast_ref.extra_data[idata.specifiers_start..idata.specifiers_end]) |raw_idx| {
                            const spec_node: NodeIndex = @enumFromInt(raw_idx);
                            const spec_tag = self.ast_ref.nodeTag(spec_node);
                            const spec_d = self.ast_ref.nodeData(spec_node);
                            switch (spec_tag) {
                                .import_specifier => {
                                    // data.lhs = imported_node (exported name), data.rhs = local_node
                                    const exp_name = self.ast_ref.tokenText(
                                        self.ast_ref.nodeMainToken(spec_d.lhs),
                                    );
                                    const local_name = self.ast_ref.tokenText(
                                        self.ast_ref.nodeMainToken(spec_d.rhs),
                                    );
                                    try self.known_type_names.put(self.gpa, local_name, {});
                                    try self.import_map.put(self.gpa, local_name, .{
                                        .module_specifier = module_spec,
                                        .exported_name = exp_name,
                                    });
                                },
                                .import_default_specifier => {
                                    // data.lhs = local_node; exported name is "default"
                                    const local_name = self.ast_ref.tokenText(
                                        self.ast_ref.nodeMainToken(spec_d.lhs),
                                    );
                                    try self.known_type_names.put(self.gpa, local_name, {});
                                    try self.import_map.put(self.gpa, local_name, .{
                                        .module_specifier = module_spec,
                                        .exported_name = "default",
                                    });
                                },
                                .import_namespace_specifier => {
                                    // data.lhs = local namespace binding node
                                    const local_name = self.ast_ref.tokenText(
                                        self.ast_ref.nodeMainToken(spec_d.lhs),
                                    );
                                    try self.known_type_names.put(self.gpa, local_name, {});
                                    try self.namespace_import_map.put(self.gpa, local_name, module_spec);
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }
        try self.buildExpandoFns();
    }

    /// Scan all assignment expressions for `funcName.prop = value` patterns.
    /// Any function/function-expression whose name appears as the root of such
    /// an LHS is an "expando function" — tsc types it as `typeof funcName`
    /// rather than the raw function signature.
    fn buildExpandoFns(self: *Checker) !void {
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const ni: NodeIndex = @enumFromInt(i);
            if (self.ast_ref.nodeTag(ni) != .assign) continue;
            const data = self.ast_ref.nodeData(ni);
            if (data.lhs == .none or data.lhs.toInt() == NONE) continue;
            // CommonJS: note `module.exports = { … }` (object-literal RHS).
            if (self.checker_opts.is_js_file and !self.module_exports_literal and
                self.isModuleExportsMember(data.lhs) and
                self.isEmptyObjectLiteral(data.rhs))
            {
                self.module_exports_literal = true;
            }
            // Direct single-level property write `foo.x = v`: remember the
            // prop so member access can type it later.
            const direct_prop: ?[]const u8 = blk: {
                if (self.ast_ref.nodeTag(data.lhs) != .member_expr) break :blk null;
                const md = self.ast_ref.nodeData(data.lhs);
                if (md.lhs == .none or md.rhs == .none) break :blk null;
                if (self.ast_ref.nodeTag(md.lhs) != .identifier) break :blk null;
                const pt = self.ast_ref.nodeMainToken(md.rhs);
                const pn = self.ast_ref.tokenText(pt);
                break :blk if (pn.len > 0) pn else null;
            };
            // Walk the LHS member chain to find the root identifier.
            var obj = data.lhs;
            var depth: u8 = 0;
            while (depth < 8) : (depth += 1) {
                const obj_tag = self.ast_ref.nodeTag(obj);
                if (obj_tag == .identifier) {
                    const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(obj));
                    if (name.len > 0) {
                        if (self.value_decl_by_name.get(name)) |decls| {
                            for (decls.items) |decl_node| {
                                switch (self.ast_ref.nodeTag(decl_node)) {
                                    .fn_decl, .async_fn_decl,
                                    .generator_fn_decl, .async_generator_fn_decl => {
                                        const gop = try self.expando_fns.getOrPut(self.gpa, name);
                                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                                        if (direct_prop) |pn| {
                                            try gop.value_ptr.append(self.gpa, .{ .name = pn, .value = data.rhs });
                                        }
                                    },
                                    // JS expando object: `var Outer = {}` with
                                    // later `Outer.x = …` — tsc (salsa) types
                                    // Outer as `typeof Outer`.
                                    .declarator => {
                                        if (!self.checker_opts.is_js_file) continue;
                                        const dd = self.ast_ref.nodeData(decl_node);
                                        // Only EMPTY literals (`var X = {}`) get the
                                        // `typeof X` expando treatment; non-empty
                                        // literals display structurally.
                                        if (!self.isEmptyObjectLiteral(dd.rhs)) continue;
                                        try self.expando_objs.put(self.gpa, name, {});
                                        const gop = try self.expando_fns.getOrPut(self.gpa, name);
                                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                                        if (direct_prop) |pn| {
                                            try gop.value_ptr.append(self.gpa, .{ .name = pn, .value = data.rhs });
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                    break;
                }
                switch (obj_tag) {
                    .member_expr, .optional_member_expr,
                    .computed_member_expr, .optional_computed_member_expr => {
                        const od = self.ast_ref.nodeData(obj);
                        if (od.lhs == .none or od.lhs.toInt() == NONE) break;
                        obj = od.lhs;
                    },
                    else => break,
                }
            }
        }
    }

    /// Tag a type-alias resolution with the alias name (`type Foo = …` → the
    /// resolved type carries name "Foo"), so the facade can expose it as
    /// ts.Type.aliasSymbol (e.g. no-floating-promises' allowForKnownSafePromises
    /// `{from:'file', name:'Foo'}` matching). `name` is part of structural
    /// interning, so a named copy stays distinct from the bare structural type —
    /// no pollution. Scoped: only composite types with no existing name (interface/
    /// class names are kept; primitives/keywords are never copied).
    fn tagAliasName(self: *Checker, id: TypeId, name: []const u8) TypeId {
        const t = self.store.get(id);
        if (std.mem.eql(u8, t.alias_name, name)) return id;
        switch (t.kind) {
            .object_t, .intersection_t, .union_t, .tuple_t, .type_ref, .function_t => {},
            else => return id,
        }
        var copy = t.*;
        copy.alias_name = name;
        return self.store.add(copy) catch id;
    }

    /// Stamp a structurally-resolved utility type (`Record<string, number>`,
    /// `Partial<Foo>`, ...) with its display name, since tsc renders these
    /// by name rather than expanding them.
    fn tagUtilityAlias(self: *Checker, id: TypeId, name: []const u8, args: []const TypeId) TypeId {
        if (args.len == 0) return id;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.gpa);
        buf.appendSlice(self.gpa, name) catch return id;
        buf.append(self.gpa, '<') catch return id;
        for (args, 0..) |a, i| {
            if (i > 0) buf.appendSlice(self.gpa, ", ") catch return id;
            const s = self.typeToString(a) catch return id;
            defer self.gpa.free(s);
            buf.appendSlice(self.gpa, s) catch return id;
        }
        buf.append(self.gpa, '>') catch return id;
        const display = self.gpa.dupe(u8, buf.items) catch return id;
        return self.tagAliasName(id, display);
    }

    fn resolveTypeRef(self: *Checker, ty_node: NodeIndex) TypeId {
        const name_tok = self.ast_ref.nodeMainToken(ty_node);
        const name = self.ast_ref.tokenText(name_tok);
        // Literal types in type position end up as a ts_type_reference
        // whose name token is the literal source — recognize the
        // common shapes and map them to the corresponding TS keyword.
        if (name.len > 0) switch (name[0]) {
            // Quoted string literal in type position → string_literal type
            // carrying the unquoted value.  Subset of `string` for
            // assignability purposes.
            '\'', '"', '`' => {
                const inner: []const u8 = if (name.len >= 2) name[1 .. name.len - 1] else "";
                return self.store.add(.{
                    .kind = .string_literal,
                    .literal_value = .{ .string = inner },
                }) catch tymod.ID_STRING;
            },
            // Numeric literal types: `0n` (bigint_literal), `0`/`1.5`
            // (number_literal).
            '0'...'9' => {
                if (name[name.len - 1] == 'n') {
                    return self.store.add(.{
                        .kind = .bigint_literal,
                        .literal_value = .{ .bigint = name[0 .. name.len - 1] },
                    }) catch tymod.ID_BIGINT;
                }
                return self.store.add(.{
                    .kind = .number_literal,
                    .literal_value = .{ .number = std.fmt.parseFloat(f64, name) catch 0 },
                }) catch tymod.ID_NUMBER;
            },
            // Negative literal type: `-2`, `-2n`.  The parser stores
            // the `-` as the main_token of a ts_type_reference and
            // discards the literal; reconstruct the value by peeking
            // at the next token's text.
            '-' => {
                const next_tok = name_tok + 1;
                if (next_tok < self.ast_ref.tokens.len) {
                    const next_text = self.ast_ref.tokenText(next_tok);
                    if (next_text.len > 0 and (next_text[0] >= '0' and next_text[0] <= '9')) {
                        if (next_text[next_text.len - 1] == 'n') {
                            // Compose "-2" for the bigint payload.
                            const composed = std.fmt.allocPrint(
                                self.gpa, "-{s}", .{next_text[0 .. next_text.len - 1]},
                            ) catch return tymod.ID_BIGINT;
                            return self.store.add(.{
                                .kind = .bigint_literal,
                                .literal_value = .{ .bigint = composed },
                            }) catch tymod.ID_BIGINT;
                        }
                        const v = std.fmt.parseFloat(f64, next_text) catch 0;
                        return self.store.add(.{
                            .kind = .number_literal,
                            .literal_value = .{ .number = -v },
                        }) catch tymod.ID_NUMBER;
                    }
                }
            },
            else => {},
        };
        if (std.mem.eql(u8, name, "true")) {
            return self.store.add(.{ .kind = .boolean_literal, .literal_value = .{ .boolean = true } }) catch tymod.ID_BOOLEAN;
        }
        if (std.mem.eql(u8, name, "false")) {
            return self.store.add(.{ .kind = .boolean_literal, .literal_value = .{ .boolean = false } }) catch tymod.ID_BOOLEAN;
        }
        // Map common built-ins to canonical types so containsAny on
        // `Array<any>` flags correctly without resolving the lib. A user that
        // shadows the name (`interface Array {…}` / `namespace N { interface
        // Array {…} }`) lands in type_decl_nodes (lib seeds never do), so skip
        // the builtin shortcut and fall through to resolveDeclaredType for it.
        if ((std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "ReadonlyArray")) and !self.type_decl_nodes.contains(name)) {
            const elem = self.firstTypeArg(ty_node);
            const inner = if (elem == .none) tymod.ID_ANY else self.resolveTypeNode(elem);
            return self.store.arrayOf(inner) catch tymod.ID_ANY;
        }
        if (std.mem.eql(u8, name, "any")) return tymod.ID_ANY;
        if (std.mem.eql(u8, name, "unknown")) return tymod.ID_UNKNOWN;
        if (std.mem.eql(u8, name, "never")) return tymod.ID_NEVER;
        if (std.mem.eql(u8, name, "string")) return tymod.ID_STRING;
        if (std.mem.eql(u8, name, "number")) return tymod.ID_NUMBER;
        if (std.mem.eql(u8, name, "boolean")) return tymod.ID_BOOLEAN;
        if (std.mem.eql(u8, name, "bigint")) return tymod.ID_BIGINT;
        if (std.mem.eql(u8, name, "symbol")) return tymod.ID_SYMBOL;
        if (std.mem.eql(u8, name, "object")) return tymod.ID_OBJECT_KW;
        if (std.mem.eql(u8, name, "void")) return tymod.ID_VOID;
        if (std.mem.eql(u8, name, "undefined")) return tymod.ID_UNDEFINED;
        if (std.mem.eql(u8, name, "null")) return tymod.ID_NULL;
        // `this` in a type position → the instance type of the nearest enclosing
        // class. This lets prefer-readonly resolve `{} as this & { … }` to an
        // intersection that includes the class's instance type.
        if (std.mem.eql(u8, name, "this")) {
            const parents = self.semantic.parent_indices;
            const NONE: u32 = @intFromEnum(NodeIndex.none);
            var p = if (ty_node.toInt() < parents.len) parents[ty_node.toInt()] else NONE;
            var guard: u8 = 0;
            while (p != NONE and guard < 32) : (guard += 1) {
                const pn: NodeIndex = @enumFromInt(p);
                if (self.ast_ref.nodeTag(pn) == .class_decl) {
                    const pd = self.ast_ref.nodeData(pn);
                    if (pd.lhs != .none) {
                        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(pd.lhs));
                        const cname = if (cd.name != .none) self.ast_ref.tokenText(self.ast_ref.nodeMainToken(cd.name)) else "";
                        return self.buildClassInstanceType(pn, cname);
                    }
                    // Class found but instance type couldn't be built → `any`.
                    return tymod.ID_ANY;
                }
                p = if (@intFromEnum(pn) < parents.len) parents[@intFromEnum(pn)] else NONE;
            }
            // `this` outside class context → `any`.
            return tymod.ID_ANY;
        }
        // Unknown name (not built-in, not declared anywhere in the file
        // or a known lib type) → error type, unless it matches a
        // type parameter in scope — in which case resolve to its
        // constraint (`<T extends X>(t: T)` should make `t` have
        // type X for the unsafe-* family).
        if (!self.known_type_names.contains(name)) {
            if (self.resolveTypeParameterConstraint(ty_node, name)) |c| return c;
            // Built-in lib types (Record, Promise, Set, Map, …) are not
            // user-declared so they never appear in known_type_names, but
            // they still have structural shapes we can resolve.
            if (self.resolveLibType(ty_node, name)) |resolved| return resolved;
            // Unresolved type name referenced by a `///<reference>`'d file
            // (e.g. `Type`, `NodeType` in the parser sources) — tsc resolves it
            // cross-file and prints the verbatim name.  Preserve the name as a
            // type_ref rather than collapsing to `any`, so annotated fields and
            // `this.x` accesses show the real type.  Only for capitalized
            // identifiers (a heuristic for "names a type", avoiding stray
            // lowercase value-ish references).
            // Lib generics we don't model structurally but whose name carries
            // semantics elsewhere (await unwrapping, spread, iteration) —
            // leaving them as a bare typeRef would block those, so keep `any`.
            const unmodeled_lib_generic = for ([_][]const u8{
                "Promise", "PromiseLike", "Awaited", "Iterable", "AsyncIterable",
                "Iterator", "AsyncIterator", "IterableIterator", "ArrayLike",
                "Generator", "AsyncGenerator", "ThisType",
            }) |g| {
                if (std.mem.eql(u8, name, g)) break true;
            } else false;
            // Qualified unresolvable name (`JSX.Element`, `dom.JSX.Element`) —
            // preserve the FULL verbatim qualified name, judged by the last
            // component being capitalized (the type name).
            {
                const qd = self.ast_ref.nodeData(ty_node);
                if (qd.lhs != .none and self.ast_ref.nodeTag(qd.lhs) == .member_expr) {
                    const md = self.ast_ref.nodeData(qd.lhs);
                    if (md.rhs != .none) {
                        const last = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
                        if (last.len > 0 and last[0] >= 'A' and last[0] <= 'Z') {
                            const qual = self.qualifiedTypeName(ty_node, md.rhs);
                            if (qual.len > 0) {
                                var qa_buf: [8]TypeId = undefined;
                                const qargs = self.collectTypeArgs(ty_node, &qa_buf);
                                return self.store.typeRef(qual, qargs) catch tymod.ID_ANY;
                            }
                        }
                    }
                }
            }
            if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z' and
                !unmodeled_lib_generic and
                // Exclude in-scope type parameters (`T`, `U`) — they resolve via
                // their constraint above, or stay generic, not a cross-file ref.
                !self.argIsInScopeTypeParam(ty_node) and
                // Exclude short generic-style names (`T`, `R`, `X2`) that are
                // almost always type params rather than cross-file types.
                !(name.len <= 2 and (name.len == 1 or (name[1] >= '0' and name[1] <= '9'))))
            {
                var ua_buf: [8]TypeId = undefined;
                const uargs = self.collectTypeArgs(ty_node, &ua_buf);
                return self.store.typeRef(name, uargs) catch tymod.ID_ANY;
            }
            // Unresolved lowercase name → `any` to match TypeScript's permissive behavior.
            return tymod.ID_ANY;
        }
        // User-declared class or interface → named type_ref so the type
        // renders as the class/interface name (matching tsc) rather than
        // expanding to the structural object shape.  Member access resolves
        // lazily via resolveDeclaredType inside memberOnApparentType.
        if (self.type_decl_nodes.get(name)) |decl| {
            const dtag = self.ast_ref.nodeTag(decl);
            if (dtag == .class_decl or dtag == .ts_interface_decl) {
                var args_buf: [8]TypeId = undefined;
                const args = self.collectTypeArgs(ty_node, &args_buf);
                return self.store.typeRef(name, args) catch tymod.ID_ANY;
            }
        }
        // Qualified type `A.B` whose last component `B` is NOT a declared
        // type anywhere (e.g. `TypeScript.AST` where AST lives in another file
        // referenced via ///<reference>) → preserve the verbatim qualified name
        // without resolving `A` structurally.  Doing this BEFORE the recursive
        // resolveDeclaredType(A) avoids cache-poisoning when `A` is a namespace
        // mid-build (its own member's annotation references `A.B`).
        // Only for a namespace/module first component — enum members
        // (`AnimalType.cat`) and class/interface qualifications resolve through
        // their own paths below.
        if (self.type_decl_nodes.get(name)) |ndecl0| {
            const ntag0 = self.ast_ref.nodeTag(ndecl0);
            if (ntag0 == .ts_namespace_decl or ntag0 == .ts_module_decl) {
                const ty_data0 = self.ast_ref.nodeData(ty_node);
                if (ty_data0.lhs != .none and self.ast_ref.nodeTag(ty_data0.lhs) == .member_expr) {
                    const md0 = self.ast_ref.nodeData(ty_data0.lhs);
                    if (md0.rhs != .none) {
                        const last = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md0.rhs));
                        if (last.len > 0 and !self.known_type_names.contains(last)) {
                            const qual = self.qualifiedTypeName(ty_node, md0.rhs);
                            if (qual.len > 0) {
                                var args_buf0: [8]TypeId = undefined;
                                const args0 = self.collectTypeArgs(ty_node, &args_buf0);
                                return self.store.typeRef(qual, args0) catch tymod.ID_ANY;
                            }
                        }
                    }
                }
            }
        }
        // User-declared enum/namespace/type-alias → resolve structurally.
        if (self.resolveDeclaredType(name)) |resolved| {
            // Qualified type `A.B`: if `A` resolved to a namespace object_t,
            // look up the property `B` on it — `A.B` is the member type, not
            // the namespace type itself.
            const ty_data = self.ast_ref.nodeData(ty_node);
            if (ty_data.lhs != .none and self.ast_ref.nodeTag(ty_data.lhs) == .member_expr) {
                const rt = self.store.get(resolved);
                // Qualified enum member type `Choice.Yes`: resolveDeclaredType
                // returned the enum's member UNION, not an object_t, so the
                // namespace-style member lookup below would silently skip the
                // `.Yes` access and yield the whole enum. Look the member up in
                // the enum's object shape instead — its props carry the
                // enum-tagged literal (renders as "Choice.Yes").
                if (self.type_decl_nodes.get(name)) |edecl| {
                    if (self.ast_ref.nodeTag(edecl) == .ts_enum_decl) {
                        const member_data = self.ast_ref.nodeData(ty_data.lhs);
                        if (member_data.rhs != .none) {
                            const member_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(member_data.rhs));
                            if (self.buildEnumObjectType(name)) |obj| {
                                const ot = self.store.get(obj);
                                if (ot.kind == .object_t) {
                                    for (self.store.propsOf(ot.object_props)) |p| {
                                        if (std.mem.eql(u8, p.name, member_name)) return p.type_id;
                                    }
                                }
                            }
                        }
                    }
                }
                if (rt.kind == .object_t) {
                    const member_data = self.ast_ref.nodeData(ty_data.lhs);
                    if (member_data.rhs != .none) {
                        const member_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(member_data.rhs));
                        for (self.store.propsOf(rt.object_props)) |p| {
                            if (!std.mem.eql(u8, p.name, member_name)) continue;
                            const prop_t = self.store.get(p.type_id);
                            const prop_kind = prop_t.kind;
                            // For class members (object_t stored in namespace) preserve the
                            // qualified name — e.g. render as "lavali.xanthognathus" not structural.
                            if (prop_kind == .object_t) {
                                const qual_name = self.qualifiedTypeName(ty_node, member_data.rhs);
                                if (qual_name.len > 0) {
                                    const display = self.displayQualifiedName(ty_node, qual_name);
                                    var args_buf2: [8]TypeId = undefined;
                                    const args2 = self.collectTypeArgs(ty_node, &args_buf2);
                                    return self.store.typeRef(display, args2) catch p.type_id;
                                }
                            }
                            // Enum inside a namespace: tsc shows it with
                            // scope-relative qualification (`First.E`).  The
                            // namespace prop may be the enum's member union or a
                            // bare type_ref to the enum name — resolve to the
                            // union for assignability and tag the display name.
                            const names_enum = prop_kind == .type_ref and
                                self.type_decl_nodes.get(prop_t.name) != null and
                                self.ast_ref.nodeTag(self.type_decl_nodes.get(prop_t.name).?) == .ts_enum_decl;
                            if (prop_kind == .union_t or prop_t.enum_name.len > 0 or names_enum) {
                                const qual_name = self.qualifiedTypeName(ty_node, member_data.rhs);
                                if (qual_name.len > 0) {
                                    const display = self.displayQualifiedName(ty_node, qual_name);
                                    const resolved_enum = if (names_enum)
                                        (self.buildEnumUnionType(prop_t.name) orelse p.type_id)
                                    else
                                        p.type_id;
                                    if (!std.mem.eql(u8, display, member_name) or prop_kind == .union_t or names_enum) {
                                        return self.tagAliasName(resolved_enum, display);
                                    }
                                }
                            }
                            return p.type_id;
                        }
                        // Member not found in the namespace's props.
                        const qual_name = self.qualifiedTypeName(ty_node, member_data.rhs);
                        var args_buf: [8]TypeId = undefined;
                        const args = self.collectTypeArgs(ty_node, &args_buf);
                        if (self.known_type_names.contains(member_name)) {
                            // A type declared elsewhere → scope-relative display:
                            // bare inside the namespace (`WriterAggregator`),
                            // qualified outside (`N.T7`).
                            const display = if (qual_name.len > 0)
                                self.displayQualifiedName(ty_node, qual_name)
                            else
                                member_name;
                            return self.store.typeRef(display, args) catch tymod.ID_ANY;
                        }
                        // Unresolvable member (`TS.AST` where AST is declared in
                        // another file via ///<reference>) — tsc preserves the
                        // verbatim qualified name rather than expanding `TS` to
                        // its namespace shape.
                        if (qual_name.len > 0) {
                            return self.store.typeRef(qual_name, args) catch tymod.ID_ANY;
                        }
                    }
                }
            }
            // Type alias instantiation: if `Foo` is a generic alias
            // (`type Foo<T> = ...`) and the use site supplies type args,
            // substitute them through the body.  For conditional type
            // bodies, resolve with the subst context directly so
            // `infer V` and type-param substitution work correctly.
            const decl_opt = self.type_decl_nodes.get(name);
            if (decl_opt) |decl| {
                if (self.ast_ref.nodeTag(decl) == .ts_type_alias_decl) {
                    const ta_dd = self.ast_ref.nodeData(decl);
                    const ta_ad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(ta_dd.lhs));
                    var result = resolved;
                    if (self.isConditionalBody(ta_ad.type_node)) {
                        if (self.resolveConditionalAliasWithArgs(decl, ty_node, ta_ad)) |inst| result = inst;
                    } else {
                        if (self.substituteAliasArgs(decl, ty_node, resolved)) |inst| result = inst;
                    }
                    // For a generic alias instantiation like `Lazy<string>`, tag
                    // the expanded result with the FULL alias string (e.g.
                    // "Lazy<string>") rather than just the bare name. This keeps the
                    // expanded type internally (so member access still works) while
                    // making typeToString emit "Lazy<string>" matching tsc.
                    // Guard: only when the expanded result is "structurally rich"
                    // (union with complex members, intersection, object, function, or
                    // type_ref). TypeScript resolves through simple aliases like
                    // `type Id<T> = T` or `type Strange<T> = string`, so we skip the
                    // full alias string for those and let tagAliasName use bare "name".
                    var use_args_buf: [8]TypeId = undefined;
                    const use_args = self.collectTypeArgsParamAware(ty_node, &use_args_buf);
                    if (use_args.len > 0) {
                        const rt = self.store.get(result);
                        const is_complex_result: bool = switch (rt.kind) {
                            .intersection_t, .object_t, .function_t, .type_ref => true,
                            .union_t => for (self.store.idsOf(rt.list_data)) |m| {
                                const mk = self.store.get(m).kind;
                                switch (mk) {
                                    .type_ref, .object_t, .function_t, .intersection_t,
                                    .array_t, .readonly_array_t, .tuple_t, .type_param => break true,
                                    else => {},
                                }
                            } else false,
                            else => false,
                        };
                        if (is_complex_result) {
                            // Build "Lazy<string>" as the alias name so serialization
                            // outputs the full generic form without changing internal type.
                            var alias_buf: std.ArrayList(u8) = .empty;
                            defer alias_buf.deinit(self.gpa);
                            alias_buf.appendSlice(self.gpa, name) catch {};
                            alias_buf.append(self.gpa, '<') catch {};
                            for (use_args, 0..) |a, ai| {
                                if (ai > 0) alias_buf.appendSlice(self.gpa, ", ") catch {};
                                if (self.typeToString(a)) |arg_str| {
                                    alias_buf.appendSlice(self.gpa, arg_str) catch {};
                                } else |_| {}
                            }
                            alias_buf.append(self.gpa, '>') catch {};
                            const alias_str = alias_buf.toOwnedSlice(self.gpa) catch name;
                            return self.tagAliasName(result, alias_str);
                        }
                    }
                    return self.tagAliasName(result, name);
                }
            }
            return resolved;
        }
        // Built-in lib types with structural shapes (Promise, Set, Map,
        // etc.).  Generic args get substituted into the method signatures.
        if (self.resolveLibType(ty_node, name)) |resolved| return resolved;
        // In type-position mode (inside ts_function_type), always return a genuine
        // type_param TypeId for in-scope type params so the function type displays
        // as `<T extends X>(x: T) => T` rather than `(x: X) => X`.
        if (self.type_pos_depth > 0 and self.argIsInScopeTypeParam(ty_node))
            return self.buildTypeParam(ty_node, name);
        // Type parameter with matching name in scope?  Resolve to its
        // constraint type (an over-approximation that lets `t: T` where
        // `T extends Foo` behave as `t: Foo`).
        if (self.resolveTypeParameterConstraint(ty_node, name)) |c| return c;
        // An in-scope but UNCONSTRAINED type parameter (`<T>`) → a genuine
        // `.type_param` (TypeParameter flag), not an opaque type_ref, so rules
        // that special-case a naked type parameter recognize it (e.g.
        // no-unnecessary-condition's isConditionalAlwaysNecessary via
        // ts.TypeFlags.TypeVariable).  Constrained params already returned their
        // constraint above.
        if (self.argIsInScopeTypeParam(ty_node)) return self.buildTypeParam(ty_node, name);
        // Qualified type name (e.g. `Namespace.Enum`): `name` is the first
        // component; try the last component of the member_expr chain so
        // `A.B` resolves to the same TypeId as bare `B` when `B` is a
        // known type (enum, interface, class) declared inside the namespace.
        {
            const ty_data = self.ast_ref.nodeData(ty_node);
            if (ty_data.lhs != .none and self.ast_ref.nodeTag(ty_data.lhs) == .member_expr) {
                const member_data = self.ast_ref.nodeData(ty_data.lhs);
                if (member_data.rhs != .none) {
                    const last_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(member_data.rhs));
                    if (self.known_type_names.contains(last_name)) {
                        // Enum member inside a namespace: resolve to the enum's
                        // member union so assignability works, displayed with
                        // tsc's scope-relative qualification (`First.E`).
                        if (self.type_decl_nodes.get(last_name)) |edecl| {
                            if (self.ast_ref.nodeTag(edecl) == .ts_enum_decl) {
                                if (self.buildEnumUnionType(last_name)) |eu| {
                                    const qual = self.qualifiedTypeName(ty_node, member_data.rhs);
                                    const display = if (qual.len > 0)
                                        self.displayQualifiedName(ty_node, qual)
                                    else
                                        last_name;
                                    return self.tagAliasName(eu, display);
                                }
                            }
                        }
                        const qual = self.qualifiedTypeName(ty_node, member_data.rhs);
                        const display = if (qual.len > 0)
                            self.displayQualifiedName(ty_node, qual)
                        else
                            last_name;
                        var args_buf: [8]TypeId = undefined;
                        const args = self.collectTypeArgs(ty_node, &args_buf);
                        return self.store.typeRef(display, args) catch tymod.ID_ANY;
                    }
                }
            }
        }
        // Qualified name rooted at a namespace-import binding
        // (`import React = require("react")` + `React.StatelessComponent<T>`):
        // preserve the full qualified display.
        {
            const qd2 = self.ast_ref.nodeData(ty_node);
            if (self.namespace_import_map.get(name) != null and
                qd2.lhs != .none and self.ast_ref.nodeTag(qd2.lhs) == .member_expr)
            {
                const md2 = self.ast_ref.nodeData(qd2.lhs);
                if (md2.rhs != .none) {
                    const qual2 = self.qualifiedTypeName(ty_node, md2.rhs);
                    if (qual2.len > 0) {
                        var qa2_buf: [8]TypeId = undefined;
                        const qargs2 = self.collectTypeArgs(ty_node, &qa2_buf);
                        return self.store.typeRef(qual2, qargs2) catch tymod.ID_ANY;
                    }
                }
            }
        }
        // Generic args: collect for the typeRef payload.
        var args_buf: [8]TypeId = undefined;
        const args = self.collectTypeArgs(ty_node, &args_buf);
        return self.store.typeRef(name, args) catch tymod.ID_ANY;
    }

    /// True when `arg` (a type-position node, possibly parenthesized) is a bare
    /// reference to a type parameter declared in an enclosing scope — i.e. a
    /// *free* generic. Used to keep conditional-type aliases deferred.
    fn argIsInScopeTypeParam(self: *Checker, arg: NodeIndex) bool {
        var n = arg;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .ts_type_reference) return false;
        // A type ref with its own args is an instantiation, not a bare param.
        if (self.ast_ref.nodeData(n).rhs != .none) return false;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
        const ty_pos = self.ast_ref.tokenStart(self.ast_ref.nodeMainToken(n));
        for (self.type_param_nodes.items) |ni| {
            if (!std.mem.eql(u8, self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ni)), name)) continue;
            if (self.ast_ref.tokenStart(self.ast_ref.nodeMainToken(ni)) < ty_pos) return true;
        }
        return false;
    }

    /// If `node` is an identifier whose binding is declared with a bare in-scope
    /// type-parameter annotation (`a: T`), return that `.type_param` (carrying its
    /// constraint); otherwise null. Lets the facade see such a value as the
    /// parameter `T` itself — so `a as T` is a safe identity, while `y as T`
    /// (y: string) is still flagged — without changing stored value types (which
    /// keep the constraint over-approximation the checker's inference relies on).
    pub fn valueTypeParam(self: *Checker, node: NodeIndex) ?TypeId {
        if (self.ast_ref.nodeTag(node) != .identifier) return null;
        const sym = self.symbolForIdentRef(node) orelse return null;
        const decl = self.semantic.symbols.getDeclNode(sym);
        if (decl == .none or self.ast_ref.nodeTag(decl) != .identifier) return null;
        const bd = self.ast_ref.nodeData(decl);
        if (bd.rhs == .none or self.ast_ref.nodeTag(bd.rhs) != .ts_type_annotation) return null;
        const ty_node = self.ast_ref.nodeData(bd.rhs).lhs;
        if (!self.argIsInScopeTypeParam(ty_node)) return null;
        const nm = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ty_node));
        return self.buildTypeParam(ty_node, nm);
    }

    /// Resolve a type node like `resolveTypeNode`, except a bare reference to an
    /// in-scope type parameter yields a genuine `.type_param` type (carrying its
    /// constraint) instead of the constraint itself. Used by the type-aware
    /// facade for *asserted* types (`x as T`) so isTypeParameter/getConstraint
    /// work and `concrete as T` is flagged unsafe — without disturbing the
    /// constraint over-approximation that value-position typing relies on.
    pub fn resolveTypeNodeParamAware(self: *Checker, ty_node: NodeIndex) TypeId {
        if (self.argIsInScopeTypeParam(ty_node)) {
            var n = ty_node;
            while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
            const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
            return self.buildTypeParam(n, name);
        }
        return self.resolveTypeNode(ty_node);
    }

    /// Find a `ts_type_parameter` declaration named `name` enclosing
    /// `ty_node` and return its constraint's resolved TypeId.  Falls
    /// back to null when no such parameter is found or it has no
    /// constraint.
    fn resolveTypeParameterConstraint(self: *Checker, ty_node: NodeIndex, name: []const u8) ?TypeId {
        // Cycle break: a constraint that refers back to its own type parameter
        // (`<T extends null extends T ? any : never>`) would recurse forever.
        for (self.tparam_names[0..self.tparam_n]) |n| {
            if (std.mem.eql(u8, n, name)) return null;
        }
        if (self.tparam_n >= self.tparam_names.len) return null;
        const best_constraint = self.typeParamConstraintNode(ty_node, name) orelse return null;
        self.tparam_names[self.tparam_n] = name;
        self.tparam_n += 1;
        defer self.tparam_n -= 1;
        const resolved = self.resolveTypeNode(best_constraint);
        // Don't substitute when the constraint is `any` — TS treats
        // `<T extends any>` as an unconstrained type parameter.
        if (tymod.isAny(&self.store, resolved)) return null;
        return resolved;
    }

    /// The constraint type *node* of the in-scope type parameter named `name`
    /// enclosing `ty_node` (innermost wins), or null if none / no constraint.
    /// Split out so type_param construction can resolve the constraint
    /// param-aware (`V extends T` → constraint is the parameter T, not its
    /// over-approximation) for constraint-chain assignability.
    fn typeParamConstraintNode(self: *Checker, ty_node: NodeIndex, name: []const u8) ?NodeIndex {
        // Walk the parent index to find an enclosing fn/class/alias
        // scope; if one is found, look for a ts_type_parameter whose
        // parent chain reaches the same scope (using main-token
        // position for "before ty_node" comparison).
        const tree = self.ast_ref;
        const parents = self.semantic.parent_indices;
        const tni = ty_node.toInt();
        if (tni >= parents.len) return null;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        // Collect ancestors in a buffer for cheap containment checks.
        var anc_buf: [16]u32 = undefined;
        var nanc: usize = 0;
        var p = parents[tni];
        while (p != NONE and p < parents.len and nanc < anc_buf.len) : (p = parents[p]) {
            anc_buf[nanc] = p;
            nanc += 1;
        }
        // Find ts_type_parameter nodes named `name` whose ancestor chain
        // includes a scope ancestor shared with ty_node.  When multiple
        // candidates match, prefer the INNERMOST scope (matches TS's
        // shadowing rules) — track the best candidate's tp_pos and
        // override when we find a later one.
        const ty_main_tok = tree.nodeMainToken(ty_node);
        const ty_pos = tree.tokenStart(ty_main_tok);
        var best_tp_pos: u32 = 0;
        var best_constraint: NodeIndex = .none;
        var found_any = false;
        for (self.type_param_nodes.items) |ni| {
            if (!std.mem.eql(u8, tree.tokenText(tree.nodeMainToken(ni)), name)) continue;
            const tp_pos = tree.tokenStart(tree.nodeMainToken(ni));
            if (tp_pos >= ty_pos) continue;
            // Determine if some ancestor of the tp is a scope that
            // also appears in ty_node's ancestor chain.
            var in_scope = false;
            for (anc_buf[0..nanc]) |anc_idx| {
                const anc: NodeIndex = @enumFromInt(anc_idx);
                const tag = tree.nodeTag(anc);
                const is_scope = tag == .fn_decl or tag == .async_fn_decl or
                    tag == .generator_fn_decl or tag == .async_generator_fn_decl or
                    tag == .ts_declare_function or tag == .fn_expr or
                    tag == .async_fn_expr or tag == .generator_fn_expr or
                    tag == .async_generator_fn_expr or tag == .arrow_fn or
                    tag == .async_arrow_fn or tag == .method_def or
                    tag == .computed_method_def or tag == .class_decl or
                    tag == .class_expr or tag == .ts_type_alias_decl or
                    tag == .ts_interface_decl or tag == .ts_function_type or
                    tag == .ts_constructor_type or tag == .ts_call_signature or
                    tag == .ts_construct_signature or tag == .ts_method_signature;
                if (!is_scope) continue;
                const anc_pos = tree.tokenStart(tree.nodeMainToken(anc));
                if (tp_pos < anc_pos) continue;
                in_scope = true;
                break;
            }
            if (!in_scope) continue;
            // Innermost wins — tp closer to ty_pos shadows outer ones.
            if (!found_any or tp_pos > best_tp_pos) {
                found_any = true;
                best_tp_pos = tp_pos;
                best_constraint = tree.nodeData(ni).lhs;
            }
        }
        if (!found_any) return null;
        if (best_constraint == .none) return null;
        return best_constraint;
    }

    /// Build a `.type_param` for the in-scope parameter `name` at `ref_node`,
    /// resolving its constraint param-aware so nested parameters (`V extends T`)
    /// stay `.type_param` — letting constraint-chain assignability decide
    /// `V as T` (safe) vs `T as V` (unsafe).
    fn buildTypeParam(self: *Checker, ref_node: NodeIndex, name: []const u8) TypeId {
        var c: TypeId = .none;
        // Resolve the constraint param-aware (so `V extends T` carries the
        // parameter T), but cap the depth — self/mutually-referential
        // constraints (`T extends Array<T>`) would otherwise recurse forever.
        if (self.tp_depth < 4) {
            if (self.typeParamConstraintNode(ref_node, name)) |cn| {
                self.tp_depth += 1;
                const r = self.resolveTypeNodeParamAware(cn);
                self.tp_depth -= 1;
                if (!tymod.isAny(&self.store, r)) c = r;
            }
        }
        return self.store.typeParam(name, c) catch tymod.ID_UNKNOWN;
    }

    /// Hardcoded lib type seeds for the most common parameterized types.
    /// Each builds an object_t with the methods that show up in our
    /// rules' fixtures.  Not a substitute for lib.d.ts; sized for the
    /// type-aware family we care about.
    fn resolveLibType(self: *Checker, ty_node: NodeIndex, name: []const u8) ?TypeId {
        var args_buf: [4]TypeId = undefined;
        // For structural utility types whose output is always object/generic
        // (never a primitive), use param-aware arg collection. When any arg
        // is an in-scope type parameter we return a generic typeRef (e.g.
        // `Readonly<P>`) rather than expanding structurally, matching tsc.
        // Excluded: Exclude/Extract/NonNullable/ReturnType/Parameters which
        // can produce primitive types and must stay structural.
        const is_structural_util = for ([_][]const u8{
            "Readonly", "Partial", "Required", "Pick", "Omit",
            "Promise", "Set", "ReadonlySet", "Map", "ReadonlyMap",
            "Record", "Awaited",
        }) |n| {
            if (std.mem.eql(u8, name, n)) break true;
        } else false;
        if (is_structural_util) {
            const param_args = self.collectTypeArgsParamAware(ty_node, &args_buf);
            const has_type_param_arg = for (param_args) |a| {
                if (self.store.get(a).kind == .type_param) break true;
            } else false;
            if (has_type_param_arg) {
                return self.store.typeRef(name, param_args) catch null;
            }
        }
        const args = self.collectTypeArgs(ty_node, &args_buf);
        if (std.mem.eql(u8, name, "Promise")) {
            const t = if (args.len > 0) args[0] else tymod.ID_UNKNOWN;
            return self.buildPromiseLib(t);
        }
        if (std.mem.eql(u8, name, "Set") or std.mem.eql(u8, name, "ReadonlySet")) {
            const t = if (args.len > 0) args[0] else tymod.ID_UNKNOWN;
            return self.buildSetLib(t, std.mem.eql(u8, name, "ReadonlySet"));
        }
        if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "ReadonlyMap")) {
            const k = if (args.len > 0) args[0] else tymod.ID_UNKNOWN;
            const v = if (args.len > 1) args[1] else tymod.ID_UNKNOWN;
            return self.buildMapLib(k, v, std.mem.eql(u8, name, "ReadonlyMap"));
        }
        // Record<K, V> structurally behaves as `{ [k: K]: V }` — we
        // model it as an object_t with a single "[]" index-signature
        // prop carrying V.  inferComputedMember already looks for this
        // sentinel prop on object_t.
        if (std.mem.eql(u8, name, "Record")) {
            const v = if (args.len > 1) args[1] else tymod.ID_UNKNOWN;
            const props = [_]tymod.ObjectProp{.{ .name = "[]", .type_id = v }};
            const list = self.store.appendObjectProps(&props) catch return null;
            const obj = self.store.add(.{ .kind = .object_t, .object_props = list }) catch return null;
            return self.tagUtilityAlias(obj, name, args);
        }
        // NonNullable<T> — remove null and undefined from T's union members.
        if (std.mem.eql(u8, name, "NonNullable")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.removeNullUndefined(t);
        }
        // Awaited<T> — recursively unwrap Promise<T>.
        if (std.mem.eql(u8, name, "Awaited")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.resolveAwaited(t);
        }
        // ReturnType<F> — extract the return type from a function type.
        if (std.mem.eql(u8, name, "ReturnType")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.resolveReturnType(t);
        }
        // Parameters<F> — extract the parameter types of F as a tuple.
        if (std.mem.eql(u8, name, "Parameters")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.resolveParameters(t);
        }
        // Partial<T> — make every property of T optional.
        if (std.mem.eql(u8, name, "Partial")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.tagUtilityAlias(self.resolvePartial(t, true), name, args);
        }
        // Required<T> — make every property of T required (non-optional).
        if (std.mem.eql(u8, name, "Required")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.tagUtilityAlias(self.resolvePartial(t, false), name, args);
        }
        // Readonly<T> — structural alias (all props readonly, same shape).
        if (std.mem.eql(u8, name, "Readonly")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            return self.tagUtilityAlias(self.resolveReadonly(t), name, args);
        }
        // Exclude<T, U> — union T minus members assignable to U.
        if (std.mem.eql(u8, name, "Exclude")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            const u = if (args.len > 1) args[1] else return tymod.ID_UNKNOWN;
            return self.resolveExclude(t, u);
        }
        // Extract<T, U> — union T keeping only members assignable to U.
        if (std.mem.eql(u8, name, "Extract")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            const u = if (args.len > 1) args[1] else return tymod.ID_UNKNOWN;
            return self.resolveExtract(t, u);
        }
        // Pick<T, K> — object type keeping only the keys in K.
        if (std.mem.eql(u8, name, "Pick")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            const k = if (args.len > 1) args[1] else return tymod.ID_UNKNOWN;
            return self.tagUtilityAlias(self.resolvePick(t, k), name, args);
        }
        // Omit<T, K> — object type without the keys in K.
        if (std.mem.eql(u8, name, "Omit")) {
            const t = if (args.len > 0) args[0] else return tymod.ID_UNKNOWN;
            const k = if (args.len > 1) args[1] else return tymod.ID_UNKNOWN;
            return self.tagUtilityAlias(self.resolveOmit(t, k), name, args);
        }
        return null;
    }

    fn removeNullUndefined(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .union_t) {
            if (t.kind == .null_t or t.kind == .undefined_t) return tymod.ID_NEVER;
            return id;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            const mt = self.store.get(m);
            if (mt.kind == .null_t or mt.kind == .undefined_t) continue;
            if (n < buf.len) { buf[n] = m; n += 1; }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch id;
    }

    fn resolveAwaited(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind == .type_ref and std.mem.eql(u8, t.name, "Promise")) {
            const args = self.store.idsOf(t.list_data);
            if (args.len > 0) return self.resolveAwaited(args[0]);
        }
        if (t.kind == .union_t) {
            var buf: [8]TypeId = undefined;
            var n: usize = 0;
            for (self.store.idsOf(t.list_data)) |m| {
                const a = self.resolveAwaited(m);
                if (n < buf.len) { buf[n] = a; n += 1; }
            }
            if (n == 0) return id;
            return self.store.unionOf(buf[0..n]) catch id;
        }
        return id;
    }

    /// Walk `sigs` and return the index of the first signature whose parameter
    /// types are compatible with `arg_types`.  "Compatible" means: for each
    /// positional argument, the argument type is assignable to the parameter
    /// type (any/unknown on either side is always compatible).  Falls back to
    /// index 0 when nothing matches or when the function is not overloaded.
    fn pickOverload(self: *Checker, sigs: []const tymod.Signature, arg_types: []const TypeId) usize {
        if (sigs.len <= 1) return 0;
        outer: for (sigs, 0..) |sig, si| {
            const params = self.store.signatureParamsOf(sig);
            if (arg_types.len > params.len) continue;
            for (arg_types, 0..) |arg_ty, ai| {
                const param_ty = params[ai];
                if (tymod.isAny(&self.store, param_ty)) continue;
                if (tymod.isAny(&self.store, arg_ty) or tymod.isUnknown(&self.store, arg_ty)) continue;
                if (self.structuralAssignable(arg_ty, param_ty, 0) == .no) continue :outer;
            }
            return si;
        }
        return 0;
    }

    fn resolveReturnType(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind == .function_t) {
            const sigs = self.store.signaturesOf(t.signatures);
            if (sigs.len > 0) return sigs[0].return_type;
        }
        if (t.kind == .union_t) {
            var buf: [8]TypeId = undefined;
            var n: usize = 0;
            for (self.store.idsOf(t.list_data)) |m| {
                const r = self.resolveReturnType(m);
                if (!r.eq(tymod.ID_UNKNOWN) and n < buf.len) { buf[n] = r; n += 1; }
            }
            if (n == 1) return buf[0];
            if (n > 1) return self.store.unionOf(buf[0..n]) catch id;
        }
        return tymod.ID_UNKNOWN;
    }

    fn resolveParameters(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind == .function_t) {
            const sigs = self.store.signaturesOf(t.signatures);
            if (sigs.len > 0) {
                const params = self.store.signatureParamsOf(sigs[0]);
                return self.store.tupleOf(params) catch tymod.ID_UNKNOWN;
            }
        }
        return tymod.ID_UNKNOWN;
    }

    fn resolvePartial(self: *Checker, id: TypeId, make_optional: bool) TypeId {
        const t = self.store.get(id);
        if (t.kind != .object_t) return id;
        const src_props = self.store.propsOf(t.object_props);
        var new_props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer new_props.deinit(self.gpa);
        for (src_props) |p| {
            new_props.append(self.gpa, .{
                .name = p.name,
                .type_id = p.type_id,
                .optional = make_optional,
                .readonly = p.readonly,
                .is_method = p.is_method,
                .is_fn_property = p.is_fn_property,
            }) catch continue;
        }
        const list = self.store.appendObjectProps(new_props.items) catch return id;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch id;
    }

    fn resolveReadonly(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .object_t) return id;
        const src_props = self.store.propsOf(t.object_props);
        var new_props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer new_props.deinit(self.gpa);
        for (src_props) |p| {
            new_props.append(self.gpa, .{
                .name = p.name,
                .type_id = p.type_id,
                .optional = p.optional,
                .readonly = true,
                .is_method = p.is_method,
                .is_fn_property = p.is_fn_property,
            }) catch continue;
        }
        const list = self.store.appendObjectProps(new_props.items) catch return id;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch id;
    }

    fn resolveExclude(self: *Checker, id: TypeId, exclude_id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .union_t) {
            if (self.simpleAssignable(id, exclude_id) == .yes) return tymod.ID_NEVER;
            return id;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            if (self.simpleAssignable(m, exclude_id) != .yes) {
                if (n < buf.len) { buf[n] = m; n += 1; }
            }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch id;
    }

    fn resolveExtract(self: *Checker, id: TypeId, extract_id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .union_t) {
            if (self.simpleAssignable(id, extract_id) == .yes) return id;
            return tymod.ID_NEVER;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            if (self.simpleAssignable(m, extract_id) == .yes) {
                if (n < buf.len) { buf[n] = m; n += 1; }
            }
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch id;
    }

    fn resolvePick(self: *Checker, id: TypeId, keys_id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .object_t) return id;
        const src_props = self.store.propsOf(t.object_props);
        var new_props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer new_props.deinit(self.gpa);
        for (src_props) |p| {
            if (self.typeContainsKey(keys_id, p.name)) {
                new_props.append(self.gpa, p) catch continue;
            }
        }
        const list = self.store.appendObjectProps(new_props.items) catch return id;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch id;
    }

    fn resolveOmit(self: *Checker, id: TypeId, keys_id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .object_t) return id;
        const src_props = self.store.propsOf(t.object_props);
        var new_props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer new_props.deinit(self.gpa);
        for (src_props) |p| {
            if (!self.typeContainsKey(keys_id, p.name)) {
                new_props.append(self.gpa, p) catch continue;
            }
        }
        const list = self.store.appendObjectProps(new_props.items) catch return id;
        return self.store.add(.{ .kind = .object_t, .object_props = list }) catch id;
    }

    /// True when `keys_type` (a string-literal union or single string literal)
    /// includes `key`.  Used by Pick/Omit.
    fn typeContainsKey(self: *const Checker, keys_type: TypeId, key: []const u8) bool {
        const t = self.store.get(keys_type);
        if (t.kind == .string_literal) {
            return std.mem.eql(u8, t.literal_value.string, key);
        }
        if (t.kind == .union_t) {
            for (self.store.idsOf(t.list_data)) |m| {
                if (self.typeContainsKey(m, key)) return true;
            }
        }
        return false;
    }

    /// Promise<T> structural shape — methods that no-floating-promises
    /// and unsafe-* rules query.  Each method's return type carries the
    /// generic arg so chains compose: `Promise<T>.then(...) → Promise<U>`
    /// where U is the handler's return.  Without inference we approximate
    /// U as unknown.
    fn buildPromiseLib(self: *Checker, t: TypeId) TypeId {
        const promise_t = self.store.typeRef("Promise", &.{t}) catch return tymod.ID_UNKNOWN;
        const unknown_promise = self.store.typeRef("Promise", &.{tymod.ID_UNKNOWN}) catch return tymod.ID_UNKNOWN;
        // `.then(onF, onR?) → Promise<unknown>` (could refine to Promise<U|V>)
        const then_sig: tymod.Signature = .{
            .params_start = self.appendTypeIdsToSigPool(&.{ tymod.ID_UNKNOWN, tymod.ID_UNKNOWN }) catch return tymod.ID_UNKNOWN,
            .params_end = @intCast(self.store.signature_param_pool.items.len),
            .return_type = unknown_promise,
        };
        const then_t = self.store.functionType(then_sig) catch return tymod.ID_UNKNOWN;
        // `.catch(onR?) → Promise<T | U>` (approximate as Promise<unknown>)
        const catch_sig: tymod.Signature = .{
            .params_start = self.appendTypeIdsToSigPool(&.{tymod.ID_UNKNOWN}) catch return tymod.ID_UNKNOWN,
            .params_end = @intCast(self.store.signature_param_pool.items.len),
            .return_type = unknown_promise,
        };
        const catch_t = self.store.functionType(catch_sig) catch return tymod.ID_UNKNOWN;
        // `.finally(handler?) → Promise<T>`
        const finally_sig: tymod.Signature = .{
            .params_start = self.appendTypeIdsToSigPool(&.{tymod.ID_UNKNOWN}) catch return tymod.ID_UNKNOWN,
            .params_end = @intCast(self.store.signature_param_pool.items.len),
            .return_type = promise_t,
        };
        const finally_t = self.store.functionType(finally_sig) catch return tymod.ID_UNKNOWN;
        // Build the type as a type_ref for assignability/containsAny
        // purposes — we DON'T return an object_t here because type_ref
        // is what propagates through generic arg semantics best.
        // Method lookup happens in inferMember through a fallback that
        // recognizes lib types and synthesizes the props on demand.
        _ = then_t;
        _ = catch_t;
        _ = finally_t;
        return promise_t;
    }

    fn buildSetLib(self: *Checker, t: TypeId, readonly: bool) TypeId {
        const name = if (readonly) "ReadonlySet" else "Set";
        return self.store.typeRef(name, &.{t}) catch tymod.ID_UNKNOWN;
    }

    fn buildMapLib(self: *Checker, k: TypeId, v: TypeId, readonly: bool) TypeId {
        const name = if (readonly) "ReadonlyMap" else "Map";
        return self.store.typeRef(name, &.{ k, v }) catch tymod.ID_UNKNOWN;
    }

    fn appendTypeIdsToSigPool(self: *Checker, ids: []const TypeId) !u32 {
        const start: u32 = @intCast(self.store.signature_param_pool.items.len);
        try self.store.signature_param_pool.appendSlice(self.gpa, ids);
        // Keep name/optional pools in sync so signatureParamOptionalsOf returns
        // consistent data (required for correct intern hash stability).
        for (ids) |_| {
            try self.store.signature_param_name_pool.append(self.gpa, "");
            try self.store.signature_param_optional_pool.append(self.gpa, false);
        }
        return start;
    }

    /// Resolve a declared type name (interface or class) to its structural
    /// object_t.  Returns null when the name isn't a declared structural
    /// True when the AST subtree at `ty_node` contains a
    /// `ts_type_reference` whose name matches `name`.  Used to detect
    /// directly-recursive type aliases before attempting to resolve
    /// their bodies.
    fn typeNodeReferences(self: *Checker, ty_node: NodeIndex, name: []const u8) bool {
        if (ty_node == .none) return false;
        const tag = self.ast_ref.nodeTag(ty_node);
        if (tag == .ts_type_reference) {
            const tok = self.ast_ref.nodeMainToken(ty_node);
            if (std.mem.eql(u8, self.ast_ref.tokenText(tok), name)) return true;
        }
        // Walk every ts_type_reference and check whether its parent
        // chain reaches `ty_node` — needed because `nodeSpan` only
        // covers the main token, not the subtree.
        const parents = self.semantic.parent_indices;
        if (parents.len == 0) return false;
        const target_idx = @intFromEnum(ty_node);
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        const total: u32 = @intCast(self.ast_ref.nodes.len);
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            const ni: NodeIndex = @enumFromInt(i);
            if (ni == ty_node) continue;
            if (self.ast_ref.nodeTag(ni) != .ts_type_reference) continue;
            const tok = self.ast_ref.nodeMainToken(ni);
            if (!std.mem.eql(u8, self.ast_ref.tokenText(tok), name)) continue;
            // Walk up parents looking for ty_node.
            var p = parents[@intFromEnum(ni)];
            while (p != NONE) : (p = parents[p]) {
                if (p == target_idx) return true;
            }
        }
        return false;
    }

    /// Public wrapper around `resolveDeclaredType` so LintContext rules can
    /// reach in for inheritance / property walks.
    pub fn resolveDeclaredTypePub(self: *Checker, name: []const u8) ?TypeId {
        return self.resolveDeclaredType(name);
    }

    /// The declaration node of a named type or value (class/interface/alias/enum
    /// via type_decl_nodes, or a function via value_decl_by_name).
    fn declNodeForName(self: *Checker, name: []const u8) ?NodeIndex {
        if (self.type_decl_nodes.get(name)) |d| return d;
        if (self.value_decl_by_name.get(name)) |list| {
            for (list.items) |ni| switch (self.ast_ref.nodeTag(ni)) {
                .fn_decl, .async_fn_decl, .generator_fn_decl,
                .async_generator_fn_decl, .ts_declare_function => return ni,
                else => {},
            };
        }
        return null;
    }

    /// `[type_params, type_params_end)` extra-data range for a generic declaration.
    fn typeParamsRangeOf(self: *Checker, decl: NodeIndex) ?struct { start: u32, end: u32 } {
        const data = self.ast_ref.nodeData(decl);
        if (data.lhs == .none) return null;
        const lhs = @intFromEnum(data.lhs);
        return switch (self.ast_ref.nodeTag(decl)) {
            .fn_decl, .async_fn_decl, .generator_fn_decl,
            .async_generator_fn_decl, .ts_declare_function => blk: {
                const d = self.ast_ref.extraData(ast.FnData, lhs);
                break :blk .{ .start = d.type_params, .end = d.type_params_end };
            },
            .class_decl, .class_expr => blk: {
                const d = self.ast_ref.extraData(ast.ClassData, lhs);
                break :blk .{ .start = d.type_params, .end = d.type_params_end };
            },
            .ts_interface_decl => blk: {
                const d = self.ast_ref.extraData(ast.InterfaceData, lhs);
                break :blk .{ .start = d.type_params, .end = d.type_params_end };
            },
            .ts_type_alias_decl => blk: {
                const d = self.ast_ref.extraData(ast.TypeAliasData, lhs);
                break :blk .{ .start = d.type_params, .end = d.type_params_end };
            },
            else => null,
        };
    }

    /// Resolved default type of the `index`-th type parameter of the declaration
    /// named `name` (`<T = number>` → number), or null if absent / no default.
    /// Backs no-unnecessary-type-arguments (`f<number>()` where `f<T = number>`).
    /// True when `name` has more than one declaration (interface merging, or a
    /// type + a separately-declared value like `interface Foo{} declare var Foo`).
    /// no-unnecessary-type-arguments must pick the right one per type/value
    /// context; we model a single decl, so stay conservative (skip) when merged.
    fn isAmbiguousDecl(self: *Checker, name: []const u8) bool {
        var nodes: [8]NodeIndex = undefined;
        var n: usize = 0;
        const add = struct {
            fn f(arr: []NodeIndex, cnt: *usize, node: NodeIndex) void {
                for (arr[0..cnt.*]) |x| if (x == node) return;
                if (cnt.* < arr.len) {
                    arr[cnt.*] = node;
                    cnt.* += 1;
                }
            }
        }.f;
        if (self.type_decl_nodes.get(name)) |d| add(&nodes, &n, d);
        if (self.value_decl_by_name.get(name)) |list| for (list.items) |ni| add(&nodes, &n, ni);
        for (self.merged_iface_extra.items) |e| if (std.mem.eql(u8, e.name, name)) add(&nodes, &n, e.node);
        return n > 1;
    }

    pub fn typeParamDefaultAtPub(self: *Checker, name: []const u8, index: u32) ?TypeId {
        if (self.isAmbiguousDecl(name)) return null;
        const decl = self.declNodeForName(name) orelse return null;
        const range = self.typeParamsRangeOf(decl) orelse return null;
        if (range.start >= range.end) return null;
        if (index >= range.end - range.start) return null;
        if (range.end > self.ast_ref.extra_data.len) return null;
        const tp: NodeIndex = @enumFromInt(self.ast_ref.extra_data[range.start + index]);
        if (self.ast_ref.nodeTag(tp) != .ts_type_parameter) return null;
        const def = self.ast_ref.nodeData(tp).rhs;
        if (def == .none) return null;
        return self.resolveTypeNode(def);
    }

    /// True when the TypeId reaches a class/interface named `name`
    /// through its declaration's `extends` chain.  Walks unions/
    /// intersections and follows declared parent classes via AST.
    pub fn typeInheritsFromName(self: *Checker, id: TypeId, name: []const u8) bool {
        return self.typeInheritsFromNameDepth(id, name, 0);
    }

    /// Same as `typeInheritsFromName` but starts from a name string.
    /// Resolves `decl_name` via the file's declared-type table, then
    /// walks its `extends` chain looking for `base_name`.
    pub fn declaredTypeInheritsFromByName(self: *Checker, decl_name: []const u8, base_name: []const u8) bool {
        if (std.mem.eql(u8, decl_name, base_name)) return true;
        const decl = self.type_decl_nodes.get(decl_name) orelse return false;
        return self.declInheritsFromName(decl, base_name, 0);
    }

    fn typeInheritsFromNameDepth(self: *Checker, id: TypeId, name: []const u8, depth: u8) bool {
        if (depth > 8) return false;
        const t = self.store.get(id);
        if (t.kind == .type_ref) {
            if (std.mem.eql(u8, t.name, name)) return true;
            // Walk the declared class's extends chain.
            const decl = self.type_decl_nodes.get(t.name) orelse return false;
            return self.declInheritsFromName(decl, name, depth + 1);
        }
        // Union: EVERY constituent must inherit (otherwise the value
        // could be a non-Error-like at runtime — matches TS's "every
        // branch must satisfy" semantics for narrowing-on-throw).
        if (t.kind == .union_t) {
            const members = self.store.idsOf(t.list_data);
            if (members.len == 0) return false;
            for (members) |m| {
                if (!self.typeInheritsFromNameDepth(m, name, depth + 1)) return false;
            }
            return true;
        }
        // Intersection: ANY constituent inheriting is enough — the
        // intersection narrows to at least that shape.
        if (t.kind == .intersection_t) {
            for (self.store.idsOf(t.list_data)) |m| {
                if (self.typeInheritsFromNameDepth(m, name, depth + 1)) return true;
            }
            return false;
        }
        return false;
    }

    /// For a class_decl / ts_interface_decl AST node, check if its
    /// `extends` clause names `name` (transitively).
    fn declInheritsFromName(self: *Checker, decl: NodeIndex, name: []const u8, depth: u8) bool {
        if (depth > 8) return false;
        const tag = self.ast_ref.nodeTag(decl);
        if (tag == .class_decl) {
            const data = self.ast_ref.nodeData(decl);
            const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(data.lhs));
            if (cd.super_class == .none) return false;
            var sc = cd.super_class;
            // Peel ts_instantiation_expr (`extends Promise<number>`) and
            // grouping wrappers.
            while (true) {
                const sct = self.ast_ref.nodeTag(sc);
                if (sct == .grouping_expr or sct == .ts_instantiation_expr) {
                    sc = self.ast_ref.nodeData(sc).lhs;
                    continue;
                }
                break;
            }
            if (self.ast_ref.nodeTag(sc) == .identifier) {
                const parent_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(sc));
                if (std.mem.eql(u8, parent_name, name)) return true;
                if (self.type_decl_nodes.get(parent_name)) |parent_decl| {
                    return self.declInheritsFromName(parent_decl, name, depth + 1);
                }
            }
            return false;
        }
        if (tag == .ts_interface_decl) {
            const data = self.ast_ref.nodeData(decl);
            const id_data = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(data.lhs));
            if (id_data.extends_end <= id_data.extends_start) return false;
            const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
            if (id_data.extends_end > ext_len) return false;
            // The extends list stores NodeIndex values (one per
            // `extends Foo<...>` type reference).  Walk each, peeling
            // ts_instantiation_expr / grouping, and read the name token.
            for (self.ast_ref.extra_data[id_data.extends_start..id_data.extends_end]) |raw| {
                var ext_node: NodeIndex = @enumFromInt(raw);
                while (true) {
                    const t = self.ast_ref.nodeTag(ext_node);
                    if (t == .grouping_expr or t == .ts_instantiation_expr) {
                        ext_node = self.ast_ref.nodeData(ext_node).lhs;
                        continue;
                    }
                    break;
                }
                if (self.ast_ref.nodeTag(ext_node) != .ts_type_reference and
                    self.ast_ref.nodeTag(ext_node) != .identifier) continue;
                const ext_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ext_node));
                if (std.mem.eql(u8, ext_name, name)) return true;
                if (self.type_decl_nodes.get(ext_name)) |parent_decl| {
                    if (self.declInheritsFromName(parent_decl, name, depth + 1)) return true;
                }
            }
            return false;
        }
        return false;
    }

    /// Resolve a name that was imported from another file.
    /// Returns null when cross-file resolution is disabled or the import can't be resolved.
    fn resolveImportedType(self: *Checker, name: []const u8) ?TypeId {
        const resolver = self.module_resolver orelse return null;
        const entry = self.import_map.get(name) orelse return null;
        const from_dir = std.fs.path.dirname(self.file_path) orelse ".";
        return resolver.resolveExportedType(
            from_dir,
            entry.module_specifier,
            entry.exported_name,
            &self.store,
            self.gpa,
        );
    }

    /// type (e.g. an import or type alias to a non-structural type).
    fn resolveDeclaredType(self: *Checker, name: []const u8) ?TypeId {
        if (self.declared_type_cache.get(name)) |cached| {
            // Resolved or sentinel (recursion in progress).
            return cached;
        }
        const decl = self.type_decl_nodes.get(name) orelse {
            // Not declared locally — try cross-file import resolution.
            if (self.resolveImportedType(name)) |imported| {
                self.declared_type_cache.put(self.gpa, name, imported) catch {};
                return imported;
            }
            // Name is imported but module resolution failed → preserve as type_ref
            // so annotations like `function f(): ImportedType {}` render as
            // `() => ImportedType` rather than `() => any`.
            if (self.import_map.get(name) != null) {
                const tr = self.store.typeRef(name, &.{}) catch tymod.ID_ANY;
                self.declared_type_cache.put(self.gpa, name, tr) catch {};
                return tr;
            }
            return null;
        };
        // Insert sentinel to break cycles (e.g. `interface Node { children: Node[] }`).
        // On OOM, skip the sentinel rather than returning null — a missing sentinel
        // risks deeper recursion on recursive types but won't silently drop results
        // for non-recursive types under memory pressure.
        self.declared_type_cache.put(self.gpa, name, tymod.ID_UNKNOWN) catch {};
        // Build interface/class structural types with type_pos_depth > 0 so that
        // unconstrained type parameters (e.g. `T` in `interface Pair<T>`) resolve to
        // `type_param("T")` rather than `any`.  This makes the cached structural type
        // substitutable: when accessed as `Pair<number>`, applyDeclTypeArgs substitutes
        // T=number throughout, converting `type_param("T")` → `number`.
        const result = switch (self.ast_ref.nodeTag(decl)) {
            .ts_interface_decl => blk: {
                self.type_pos_depth += 1;
                defer self.type_pos_depth -= 1;
                break :blk self.buildInterfaceType(decl);
            },
            .class_decl => blk: {
                self.type_pos_depth += 1;
                defer self.type_pos_depth -= 1;
                break :blk self.buildClassInstanceType(decl, name);
            },
            // A value typed `: Fruit` has the union of the enum's member literals
            // (the enum's type-side). unionOf collapses a single-member enum to
            // its one literal and absorbs members into `string`/`number` in a
            // wrapping union — matching tsc, which is what keeps
            // no-unsafe-enum-comparison FP-safe on `Enum | string` etc.
            .ts_enum_decl => self.buildEnumUnionType(name) orelse {
                _ = self.declared_type_cache.remove(name);
                return null;
            },
            .ts_namespace_decl, .ts_module_decl => self.buildNamespaceType(decl),
            .ts_type_alias_decl => blk: {
                // `type Foo = ...` — resolve the alias body. The sentinel
                // ID_UNKNOWN already in the cache breaks any recursive
                // self-references, leaving ID_UNKNOWN holes at those positions.
                // We keep (and cache) the partially-resolved result so
                // consumers get a usable structural shape rather than null.
                const dd = self.ast_ref.nodeData(decl);
                const ad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(dd.lhs));
                const r = self.resolveTypeNode(ad.type_node);
                break :blk r;
            },
            else => {
                _ = self.declared_type_cache.remove(name);
                return null;
            },
        };
        self.declared_type_cache.put(self.gpa, name, result) catch {};
        return result;
    }

    /// Build an object_t from a namespace/module body.  Exported `const`/`let`
    /// declarators and `function`/`class` declarations become ObjectProps on the
    /// namespace value type.  Declaration-merged extras are folded in too.
    fn buildNamespaceType(self: *Checker, decl: NodeIndex) TypeId {
        var props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer props.deinit(self.gpa);

        self.collectNamespaceProps(decl, &props);

        const ns_name_tok = self.ast_ref.nodeMainToken(self.ast_ref.nodeData(decl).lhs);
        const ns_name = self.ast_ref.tokenText(ns_name_tok);
        for (self.merged_ns_extra.items) |entry| {
            if (!std.mem.eql(u8, entry.name, ns_name)) continue;
            self.collectNamespaceProps(entry.node, &props);
        }

        if (props.items.len == 0) return tymod.ID_UNKNOWN;
        const prop_list = self.store.appendObjectProps(props.items) catch return tymod.ID_UNKNOWN;
        return self.store.add(.{ .kind = .object_t, .object_props = prop_list }) catch tymod.ID_UNKNOWN;
    }

    fn collectNamespaceProps(self: *Checker, decl: NodeIndex, props: *std.ArrayList(tymod.ObjectProp)) void {
        const ns_data = self.ast_ref.nodeData(decl);
        const body = ns_data.rhs;
        if (body == .none) return;
        if (self.ast_ref.nodeTag(body) != .block_stmt) return;
        const bd = self.ast_ref.nodeData(body);
        const start = @intFromEnum(bd.lhs);
        const end = @intFromEnum(bd.rhs);
        if (start >= end or end > self.ast_ref.extra_data.len) return;
        for (self.ast_ref.extra_data[start..end]) |raw| {
            const stmt: NodeIndex = @enumFromInt(raw);
            self.collectNamespaceMemberProp(stmt, props);
        }
    }

    fn collectNamespaceMemberProp(self: *Checker, stmt: NodeIndex, props: *std.ArrayList(tymod.ObjectProp)) void {
        const stmt_tag = self.ast_ref.nodeTag(stmt);
        switch (stmt_tag) {
            .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
            .ts_declare_function => {
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(self.ast_ref.nodeData(stmt).lhs));
                if (fd.name == .none) return;
                const fn_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(fd.name));
                const fn_ty = self.typeOf(stmt);
                props.append(self.gpa, .{ .name = fn_name, .type_id = fn_ty, .is_method = true }) catch {};
            },
            .class_decl => {
                const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(self.ast_ref.nodeData(stmt).lhs));
                if (cd.name == .none) return;
                const cls_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(cd.name));
                const cls_ty = self.buildClassInstanceType(stmt, cls_name);
                props.append(self.gpa, .{ .name = cls_name, .type_id = cls_ty }) catch {};
            },
            .ts_enum_decl => {
                const ed = self.ast_ref.extraData(ast.EnumData, @intFromEnum(self.ast_ref.nodeData(stmt).lhs));
                const enum_name = self.ast_ref.tokenText(ed.name);
                const enum_ty = self.store.typeRef(enum_name, &.{}) catch tymod.ID_UNKNOWN;
                props.append(self.gpa, .{ .name = enum_name, .type_id = enum_ty }) catch {};
            },
            .ts_namespace_decl, .ts_module_decl => {
                const ns_name_node = self.ast_ref.nodeData(stmt).lhs;
                if (ns_name_node == .none) return;
                const ns_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ns_name_node));
                const ns_ty = self.resolveDeclaredType(ns_name) orelse tymod.ID_UNKNOWN;
                props.append(self.gpa, .{ .name = ns_name, .type_id = ns_ty }) catch {};
            },
            .var_decl, .let_decl, .const_decl,
            .export_named, .export_default_fn, .export_default_class => {
                self.collectNamespaceDeclProps(stmt, props);
            },
            else => {},
        }
    }

    fn collectNamespaceDeclProps(self: *Checker, stmt: NodeIndex, props: *std.ArrayList(tymod.ObjectProp)) void {
        const stmt_tag = self.ast_ref.nodeTag(stmt);
        if (stmt_tag == .export_named) {
            // `export var/let/const/fn/class/enum X` — lhs = inner decl, rhs = .none.
            const inner = self.ast_ref.nodeData(stmt).lhs;
            if (inner != .none) self.collectNamespaceMemberProp(inner, props);
            return;
        }
        if (stmt_tag == .export_default_fn or stmt_tag == .export_default_class) {
            const inner = self.ast_ref.nodeData(stmt).lhs;
            if (inner != .none) self.collectNamespaceMemberProp(inner, props);
            return;
        }
        if (stmt_tag != .var_decl and stmt_tag != .let_decl and stmt_tag != .const_decl) return;
        const d = self.ast_ref.nodeData(stmt);
        const range = self.safeSubRange(d.lhs) orelse return;
        for (self.ast_ref.extra_data[range.start..range.end]) |raw| {
            const decl_node: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(decl_node) != .declarator) continue;
            const dd = self.ast_ref.nodeData(decl_node);
            if (dd.lhs == .none or self.ast_ref.nodeTag(dd.lhs) != .identifier) continue;
            const vname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(dd.lhs));
            const vty = if (dd.rhs != .none) self.typeOf(dd.rhs) else tymod.ID_UNKNOWN;
            props.append(self.gpa, .{ .name = vname, .type_id = vty }) catch {};
        }
    }

    /// Recursively flatten all inherited props from a named type's
    /// extends/super chain into `props`.  Caps at depth 6 and deduplicates
    /// parent names (diamond inheritance safe).
    fn flattenInheritedProps(
        self: *Checker,
        parent_name: []const u8,
        depth: u8,
        seen: *[8][]const u8,
        seen_n: *u8,
        props: *std.ArrayList(tymod.ObjectProp),
    ) void {
        if (depth > 6 or seen_n.* >= seen.len) return;
        // Dedup: skip if already visited.
        for (seen[0..seen_n.*]) |s| {
            if (std.mem.eql(u8, s, parent_name)) return;
        }
        seen[seen_n.*] = parent_name;
        seen_n.* += 1;

        const parent_ty = self.resolveDeclaredType(parent_name) orelse return;
        // If the parent resolved to a type_ref (e.g. `type Pair<T> = AB<T, T>`
        // resolves to type_ref("AB", [T, T])), follow it one level to reach the
        // structural object type with type args applied.
        var structural = parent_ty;
        if (self.store.get(structural).kind == .type_ref) {
            const tr_name = self.store.get(structural).name;
            if (self.resolveDeclaredType(tr_name)) |inner| {
                structural = self.applyDeclTypeArgs(structural, tr_name, inner);
            }
        }
        const pt = self.store.get(structural);
        if (pt.kind != .object_t) return;
        for (self.store.propsOf(pt.object_props)) |p| {
            props.append(self.gpa, p) catch {};
        }
        // Recurse into the parent's own extends/super chain.
        const decl = self.type_decl_nodes.get(parent_name) orelse return;
        switch (self.ast_ref.nodeTag(decl)) {
            .ts_interface_decl => {
                const d = self.ast_ref.nodeData(decl);
                const id2 = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(d.lhs));
                if (id2.extends_end <= id2.extends_start) return;
                for (self.ast_ref.extra_data[id2.extends_start..id2.extends_end]) |raw| {
                    var en: NodeIndex = @enumFromInt(raw);
                    while (true) {
                        const tt = self.ast_ref.nodeTag(en);
                        if (tt == .grouping_expr or tt == .ts_instantiation_expr) {
                            en = self.ast_ref.nodeData(en).lhs; continue;
                        }
                        break;
                    }
                    if (self.ast_ref.nodeTag(en) != .ts_type_reference and
                        self.ast_ref.nodeTag(en) != .identifier) continue;
                    const gname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(en));
                    self.flattenInheritedProps(gname, depth + 1, seen, seen_n, props);
                }
            },
            .class_decl => {
                const d = self.ast_ref.nodeData(decl);
                const cd2 = self.ast_ref.extraData(ast.ClassData, @intFromEnum(d.lhs));
                if (cd2.super_class == .none) return;
                var sc = cd2.super_class;
                while (self.ast_ref.nodeTag(sc) == .grouping_expr or
                       self.ast_ref.nodeTag(sc) == .ts_instantiation_expr)
                    sc = self.ast_ref.nodeData(sc).lhs;
                if (self.ast_ref.nodeTag(sc) != .identifier) return;
                const gname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(sc));
                self.flattenInheritedProps(gname, depth + 1, seen, seen_n, props);
            },
            else => {},
        }
    }

    /// Build an object_t from an interface declaration's body.  Each
    /// `ts_property_signature` / `ts_method_signature` becomes one
    /// ObjectProp.  Method signatures resolve to a function_t for that
    /// method.  Extends clauses are flattened through the full hierarchy.
    fn buildInterfaceType(self: *Checker, decl: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(decl);
        const id = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(data.lhs));
        var props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer props.deinit(self.gpa);
        // Direct base types (the `extends` clause) recorded as type_refs so the
        // facade's getBaseTypes can answer isBuiltinSymbolLike — e.g.
        // no-unsafe-call's `interface X extends Function` detection.
        var base_buf: [8]TypeId = undefined;
        var base_n: usize = 0;
        // Inherit props through the full extends chain.
        if (id.extends_end > id.extends_start) {
            var seen: [8][]const u8 = undefined;
            var seen_n: u8 = 0;
            const extends = self.ast_ref.extra_data[id.extends_start..id.extends_end];
            for (extends) |raw| {
                var ext_node: NodeIndex = @enumFromInt(raw);
                while (true) {
                    const t_tag = self.ast_ref.nodeTag(ext_node);
                    if (t_tag == .grouping_expr or t_tag == .ts_instantiation_expr) {
                        ext_node = self.ast_ref.nodeData(ext_node).lhs;
                        continue;
                    }
                    break;
                }
                if (self.ast_ref.nodeTag(ext_node) != .ts_type_reference and
                    self.ast_ref.nodeTag(ext_node) != .identifier) continue;
                const ext_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ext_node));
                if (base_n < base_buf.len) {
                    // Keep the base's type args (`extends Promise<any>`) so the
                    // facade can unwrap an interface that extends a Promise.
                    var ta_buf: [4]TypeId = undefined;
                    const ta = self.collectTypeArgs(ext_node, &ta_buf);
                    if (self.store.typeRef(ext_name, ta)) |br| {
                        base_buf[base_n] = br;
                        base_n += 1;
                    } else |_| {}
                }
                self.flattenInheritedProps(ext_name, 0, &seen, &seen_n, &props);
            }
        }
        // Call/construct signatures (`(): T` / `new (): T`) — kept on the
        // object's `.signatures` so the facade's getCallSignatures /
        // getConstructSignatures work (no-unsafe-call's `interface X extends
        // Function` decides safety from these).
        var sig_buf: [8]tymod.Signature = undefined;
        var sig_n: usize = 0;
        // Call/construct signatures contributed by merged (extra) declarations of
        // the same interface name. TS orders later-declared overloads BEFORE the
        // first declaration's, so these are emitted first in the final list.
        var extra_sig_buf: [8]tymod.Signature = undefined;
        var extra_sig_n: usize = 0;
        if (id.body_end > id.body_start) {
            const body = self.ast_ref.extra_data[id.body_start..id.body_end];
            for (body) |raw| {
                const member: NodeIndex = @enumFromInt(raw);
                const mtag = self.ast_ref.nodeTag(member);
                if (mtag == .ts_call_signature or mtag == .ts_construct_signature) {
                    const mdata = self.ast_ref.nodeData(member);
                    if (mdata.lhs == .none) continue;
                    const sd = self.ast_ref.extraData(ast.InterfaceSigData, @intFromEnum(mdata.lhs));
                    if (self.buildSignatureRaw(sd.params_start, sd.params_end, sd.return_type, .none, false, false)) |raw_sig| {
                        if (sig_n < sig_buf.len) {
                            var sig = raw_sig;
                            sig.is_construct = (mtag == .ts_construct_signature);
                            sig_buf[sig_n] = sig;
                            sig_n += 1;
                        }
                    }
                    continue;
                }
                if (self.interfaceMemberToProp(member)) |p| {
                    // Merge same-named method signatures into a multi-sig function_t
                    // instead of creating duplicate props (tsc renders overloads as
                    // `{ sig1; sig2; }` — an object type, not a function type).
                    var merged = false;
                    if (self.store.get(p.type_id).kind == .function_t) {
                        for (props.items) |*existing| {
                            if (std.mem.eql(u8, existing.name, p.name) and
                                self.store.get(existing.type_id).kind == .function_t)
                            {
                                existing.type_id = self.mergeFunctionTypes(existing.type_id, p.type_id);
                                merged = true;
                                break;
                            }
                        }
                    }
                    if (!merged) props.append(self.gpa, p) catch {};
                }
            }
        }
        // Declaration merging: add members from any extra declarations with the same name.
        const iface_name = self.ast_ref.tokenText(id.name);
        for (self.merged_iface_extra.items) |entry| {
            if (!std.mem.eql(u8, entry.name, iface_name)) continue;
            const extra_data = self.ast_ref.nodeData(entry.node);
            const extra_id = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(extra_data.lhs));
            if (extra_id.body_end > extra_id.body_start) {
                const extra_body = self.ast_ref.extra_data[extra_id.body_start..extra_id.body_end];
                for (extra_body) |raw| {
                    const member: NodeIndex = @enumFromInt(raw);
                    const mtag = self.ast_ref.nodeTag(member);
                    // Call/construct signatures from merged declarations must be
                    // carried too (no-misused-promises reads all overloads to
                    // decide if a thenable callback is accepted by any of them).
                    if (mtag == .ts_call_signature or mtag == .ts_construct_signature) {
                        const mdata = self.ast_ref.nodeData(member);
                        if (mdata.lhs == .none) continue;
                        const sd = self.ast_ref.extraData(ast.InterfaceSigData, @intFromEnum(mdata.lhs));
                        if (self.buildSignatureRaw(sd.params_start, sd.params_end, sd.return_type, .none, false, false)) |raw_sig| {
                            if (extra_sig_n < extra_sig_buf.len) {
                                var sig = raw_sig;
                                sig.is_construct = (mtag == .ts_construct_signature);
                                extra_sig_buf[extra_sig_n] = sig;
                                extra_sig_n += 1;
                            }
                        }
                        continue;
                    }
                    if (self.interfaceMemberToProp(member)) |p| {
                        var merged = false;
                        if (self.store.get(p.type_id).kind == .function_t) {
                            for (props.items) |*existing| {
                                if (std.mem.eql(u8, existing.name, p.name) and
                                    self.store.get(existing.type_id).kind == .function_t)
                                {
                                    existing.type_id = self.mergeFunctionTypes(existing.type_id, p.type_id);
                                    merged = true;
                                    break;
                                }
                            }
                        }
                        if (!merged) props.append(self.gpa, p) catch {};
                    }
                }
            }
        }
        // Merge index-signature props by sentinel kind:
        //   "[]L" — Lowercase<string> key: kept as a specific sentinel
        //   "[]U" — Uppercase<string> key: kept as a specific sentinel
        //   "[]"  — generic key: kept as combined union of ALL index-sig types
        // The specific sentinels allow chainCheckType to pick the right branch
        // for all-lowercase / all-uppercase accessor names, avoiding spurious
        // nullable unions when both Lowercase and Uppercase sigs coexist.
        var idx_gen_buf: [8]tymod.TypeId = undefined;
        var idx_gen_count: usize = 0;
        var idx_gen_opt: bool = false;
        var idx_low_buf: [8]tymod.TypeId = undefined;
        var idx_low_count: usize = 0;
        var idx_low_opt: bool = false;
        var idx_up_buf: [8]tymod.TypeId = undefined;
        var idx_up_count: usize = 0;
        var idx_up_opt: bool = false;
        {
            var j: usize = 0;
            while (j < props.items.len) {
                const p = props.items[j];
                if (std.mem.eql(u8, p.name, "[]")) {
                    if (idx_gen_count < idx_gen_buf.len) {
                        idx_gen_buf[idx_gen_count] = p.type_id;
                        idx_gen_count += 1;
                        if (p.optional) idx_gen_opt = true;
                    }
                    _ = props.orderedRemove(j);
                } else if (std.mem.eql(u8, p.name, "[]L")) {
                    if (idx_low_count < idx_low_buf.len) {
                        idx_low_buf[idx_low_count] = p.type_id;
                        idx_low_count += 1;
                        if (p.optional) idx_low_opt = true;
                    }
                    _ = props.orderedRemove(j);
                } else if (std.mem.eql(u8, p.name, "[]U")) {
                    if (idx_up_count < idx_up_buf.len) {
                        idx_up_buf[idx_up_count] = p.type_id;
                        idx_up_count += 1;
                        if (p.optional) idx_up_opt = true;
                    }
                    _ = props.orderedRemove(j);
                } else {
                    j += 1;
                }
            }
        }
        // Emit "[]L" and "[]U" as specific sentinels.
        if (idx_low_count == 1) {
            props.append(self.gpa, .{ .name = "[]L", .type_id = idx_low_buf[0], .optional = idx_low_opt }) catch {};
        } else if (idx_low_count > 1) {
            const u = self.store.unionOf(idx_low_buf[0..idx_low_count]) catch tymod.ID_UNKNOWN;
            props.append(self.gpa, .{ .name = "[]L", .type_id = u, .optional = idx_low_opt }) catch {};
        }
        if (idx_up_count == 1) {
            props.append(self.gpa, .{ .name = "[]U", .type_id = idx_up_buf[0], .optional = idx_up_opt }) catch {};
        } else if (idx_up_count > 1) {
            const u = self.store.unionOf(idx_up_buf[0..idx_up_count]) catch tymod.ID_UNKNOWN;
            props.append(self.gpa, .{ .name = "[]U", .type_id = u, .optional = idx_up_opt }) catch {};
        }
        // Emit combined "[]" — union of ALL index-sig types for generic-key lookups.
        {
            var all_buf: [24]tymod.TypeId = undefined;
            var all_count: usize = 0;
            const all_opt = idx_gen_opt or idx_low_opt or idx_up_opt;
            for (idx_gen_buf[0..idx_gen_count]) |tid| {
                if (all_count < all_buf.len) { all_buf[all_count] = tid; all_count += 1; }
            }
            for (idx_low_buf[0..idx_low_count]) |tid| {
                if (all_count < all_buf.len) { all_buf[all_count] = tid; all_count += 1; }
            }
            for (idx_up_buf[0..idx_up_count]) |tid| {
                if (all_count < all_buf.len) { all_buf[all_count] = tid; all_count += 1; }
            }
            if (all_count == 1) {
                props.append(self.gpa, .{ .name = "[]", .type_id = all_buf[0], .optional = all_opt }) catch {};
            } else if (all_count > 1) {
                const u = self.store.unionOf(all_buf[0..all_count]) catch tymod.ID_UNKNOWN;
                props.append(self.gpa, .{ .name = "[]", .type_id = u, .optional = all_opt }) catch {};
            }
        }
        const list = self.store.appendObjectProps(props.items) catch return tymod.ID_UNKNOWN;
        // Tag the object with the interface name + base-type refs (in list_data)
        // — object_t doesn't otherwise use either — so the facade can expose
        // getSymbol()/getBaseTypes() for isBuiltinSymbolLike.
        const base_list = if (base_n == 0) tymod.TypeIdList.empty else (self.store.appendTypeIds(base_buf[0..base_n]) catch tymod.TypeIdList.empty);
        // Merge signatures: later-declared (extra) overloads first, then the
        // first declaration's — matching TS overload precedence.
        var all_sig_buf: [16]tymod.Signature = undefined;
        var all_sig_n: usize = 0;
        for (extra_sig_buf[0..extra_sig_n]) |s| {
            if (all_sig_n < all_sig_buf.len) { all_sig_buf[all_sig_n] = s; all_sig_n += 1; }
        }
        for (sig_buf[0..sig_n]) |s| {
            if (all_sig_n < all_sig_buf.len) { all_sig_buf[all_sig_n] = s; all_sig_n += 1; }
        }
        const sig_list = if (all_sig_n == 0) tymod.SignatureList.empty else (self.store.appendSignatures(all_sig_buf[0..all_sig_n]) catch tymod.SignatureList.empty);
        return self.store.add(.{ .kind = .object_t, .object_props = list, .name = iface_name, .list_data = base_list, .signatures = sig_list }) catch tymod.ID_UNKNOWN;
    }

    /// Return the index-signature sentinel for an interface/type-literal member.
    /// Build the fully-qualified type name from the source text for a qualified
    /// ts_type_reference like `lavali.xanthognathus` or `Harness.Compiler.C`.
    /// Returns a slice into the source (zero-allocation, valid for checker lifetime).
    /// Returns "" if the span cannot be computed.
    /// Strip enclosing-namespace prefixes from a qualified type name for
    /// display: tsc shows the minimal qualification relative to the use site.
    /// `First.E` referenced at top level stays "First.E"; inside
    /// `namespace First` it becomes "E".
    fn displayQualifiedName(self: *Checker, use_site: NodeIndex, qual: []const u8) []const u8 {
        var result = qual;
        const parents = self.semantic.parent_indices;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var p = if (use_site.toInt() < parents.len) parents[use_site.toInt()] else NONE;
        var depth: u16 = 0;
        while (p != NONE and depth < 64) : (depth += 1) {
            const pn: NodeIndex = @enumFromInt(p);
            const tag = self.ast_ref.nodeTag(pn);
            if (tag == .ts_namespace_decl or tag == .ts_module_decl) {
                const nd = self.ast_ref.nodeData(pn);
                if (nd.lhs != .none) {
                    const ns_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(nd.lhs));
                    if (ns_name.len > 0 and result.len > ns_name.len and
                        std.mem.startsWith(u8, result, ns_name) and result[ns_name.len] == '.')
                    {
                        result = result[ns_name.len + 1 ..];
                    }
                }
            }
            p = parents[p];
        }
        return result;
    }

    fn qualifiedTypeName(self: *Checker, ty_node: NodeIndex, member_rhs: NodeIndex) []const u8 {
        const name_tok = self.ast_ref.nodeMainToken(ty_node);
        const rhs_tok = self.ast_ref.nodeMainToken(member_rhs);
        const start = self.ast_ref.tokenStart(name_tok);
        const rhs_start = self.ast_ref.tokenStart(rhs_tok);
        const rhs_len = self.ast_ref.tokens.items(.len)[rhs_tok];
        const end = rhs_start + rhs_len;
        const src = self.ast_ref.source;
        if (start >= end or end > src.len) return "";
        return src[start..end];
    }

    /// Extract key_name and key_is_number from a ts_index_signature node for
    /// display purposes.  Returns .{ key_name, is_number } where key_name is
    /// a slice into the source text (valid for the checker's lifetime) and
    /// is_number is true when the key type resolves to `number`.
    fn indexSigDisplayInfo(self: *Checker, member: NodeIndex) struct { key_name: []const u8, is_number: bool } {
        const d = self.ast_ref.nodeData(member);
        const key_param = d.lhs;
        var key_name: []const u8 = "key";
        if (key_param != .none and self.ast_ref.nodeTag(key_param) == .identifier) {
            key_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(key_param));
        }
        var is_number = false;
        if (key_param != .none) {
            const key_ann = self.ast_ref.nodeData(key_param).rhs;
            if (key_ann != .none) {
                const key_ty_node = if (self.ast_ref.nodeTag(key_ann) == .ts_type_annotation)
                    self.ast_ref.nodeData(key_ann).lhs
                else
                    key_ann;
                if (key_ty_node != .none and self.ast_ref.nodeTag(key_ty_node) == .ts_type_reference) {
                    const kt_tok = self.ast_ref.nodeMainToken(key_ty_node);
                    const kt_name = self.ast_ref.tokenText(kt_tok);
                    is_number = std.mem.eql(u8, kt_name, "number");
                }
            }
        }
        return .{ .key_name = key_name, .is_number = is_number };
    }

    /// "[]"  = generic key (string/number/symbol)
    /// "[]L" = Lowercase<string> key — only matches all-lowercase accessor names
    /// "[]U" = Uppercase<string> key — only matches all-uppercase accessor names
    fn indexSigSentinel(self: *Checker, member: NodeIndex) []const u8 {
        const d = self.ast_ref.nodeData(member);
        const key_param = d.lhs;
        if (key_param == .none or self.ast_ref.nodeTag(key_param) != .identifier) return "[]";
        const key_ann = self.ast_ref.nodeData(key_param).rhs;
        if (key_ann == .none) return "[]";
        const key_ty = if (self.ast_ref.nodeTag(key_ann) == .ts_type_annotation)
            self.ast_ref.nodeData(key_ann).lhs
        else
            key_ann;
        if (key_ty == .none or self.ast_ref.nodeTag(key_ty) != .ts_type_reference) return "[]";
        const kt_data = self.ast_ref.nodeData(key_ty);
        const name_node = kt_data.lhs;
        if (name_node == .none or self.ast_ref.nodeTag(name_node) != .identifier) return "[]";
        const type_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(name_node));
        if (!std.mem.eql(u8, type_name, "Lowercase") and !std.mem.eql(u8, type_name, "Uppercase")) return "[]";
        if (kt_data.rhs == .none) return "[]";
        const sr = self.ast_ref.extraData(SubRange, @intFromEnum(kt_data.rhs));
        if (sr.end != sr.start + 1 or sr.start >= self.ast_ref.extra_data.len) return "[]";
        const arg: NodeIndex = @enumFromInt(self.ast_ref.extra_data[sr.start]);
        if (self.ast_ref.nodeTag(arg) != .ts_type_reference) return "[]";
        const arg_name_nd = self.ast_ref.nodeData(arg).lhs;
        if (arg_name_nd == .none or self.ast_ref.nodeTag(arg_name_nd) != .identifier) return "[]";
        if (!std.mem.eql(u8, self.ast_ref.tokenText(self.ast_ref.nodeMainToken(arg_name_nd)), "string")) return "[]";
        return if (std.mem.eql(u8, type_name, "Lowercase")) "[]L" else "[]U";
    }

    fn interfaceMemberToProp(self: *Checker, member: NodeIndex) ?tymod.ObjectProp {
        const tag = self.ast_ref.nodeTag(member);
        const data = self.ast_ref.nodeData(member);
        switch (tag) {
            .ts_property_signature => {
                if (data.lhs == .none) return null;
                const name_tok = self.ast_ref.nodeMainToken(data.lhs);
                const name = self.ast_ref.tokenText(name_tok);
                var ty: TypeId = tymod.ID_UNKNOWN;
                if (data.rhs != .none and self.ast_ref.nodeTag(data.rhs) == .ts_type_annotation) {
                    const ty_node = self.ast_ref.nodeData(data.rhs).lhs;
                    ty = self.resolveTypeNode(ty_node);
                }
                const optional = propertyHasOptionalMarker(self, data.lhs);
                return .{ .name = name, .type_id = ty, .optional = optional };
            },
            .ts_method_signature => {
                const sig_data = self.ast_ref.extraData(ast.InterfaceSigData, @intFromEnum(data.lhs));
                if (sig_data.key == .none) return null;
                const name_tok = self.ast_ref.nodeMainToken(sig_data.key);
                const name = self.ast_ref.tokenText(name_tok);
                // Build a function_t for the method.
                const fn_ty = self.buildFunctionType(
                    sig_data.params_start,
                    sig_data.params_end,
                    sig_data.return_type,
                    .none,
                    false,
                    false,
                );
                if (sig_data.type_params < sig_data.type_params_end) {
                    self.registerFnTypeParams(fn_ty, sig_data.type_params, sig_data.type_params_end);
                    // Also register per-signature (pool-indexed) so overload
                    // merging keeps the `<U>` prefix per slot.
                    const ft = self.store.get(fn_ty);
                    if (ft.kind == .function_t) {
                        const sl = ft.signatures;
                        if (self.store.signaturesOf(sl).len == 1) {
                            self.registerSigTypeParams(sl.start, sig_data.type_params, sig_data.type_params_end);
                        }
                    }
                }
                return .{ .name = name, .type_id = fn_ty, .is_method = true };
            },
            .ts_index_signature => {
                if (data.rhs == .none) return null;
                const value_node = if (self.ast_ref.nodeTag(data.rhs) == .ts_type_annotation)
                    self.ast_ref.nodeData(data.rhs).lhs
                else
                    data.rhs;
                const value_ty = self.resolveTypeNode(value_node);
                const sentinel = self.indexSigSentinel(member);
                const display = self.indexSigDisplayInfo(member);
                return .{ .name = sentinel, .type_id = value_ty, .index_key_name = display.key_name, .index_key_is_number = display.is_number };
            },
            else => return null,
        }
    }

    /// Merge two function_t types into one multi-sig function_t by appending
    /// the signatures of `new_ty` after those of `existing_ty`.
    fn mergeFunctionTypes(self: *Checker, existing_ty: TypeId, new_ty: TypeId) TypeId {
        const et = self.store.get(existing_ty);
        const nt = self.store.get(new_ty);
        if (et.kind != .function_t or nt.kind != .function_t) return new_ty;
        // Snapshot the SignatureList headers before any store mutation — the
        // `et`/`nt` pointers can be invalidated by appendSignatures.
        const e_list = et.signatures;
        const n_list = nt.signatures;
        const existing_sigs = self.store.signaturesOf(e_list);
        const new_sigs = self.store.signaturesOf(n_list);
        var sig_buf: [8]tymod.Signature = undefined;
        // Original pool index of each copied signature, for carrying the
        // per-signature type-param prefix (`<U>`) registry entries — keyed by
        // pool index, they would otherwise be lost in the copy.
        var src_idx: [8]u32 = undefined;
        var n: usize = 0;
        for (existing_sigs, 0..) |s, i| {
            if (n >= sig_buf.len) break;
            sig_buf[n] = s;
            src_idx[n] = e_list.start + @as(u32, @intCast(i));
            n += 1;
        }
        for (new_sigs, 0..) |s, j| {
            if (n >= sig_buf.len) break;
            sig_buf[n] = s;
            src_idx[n] = n_list.start + @as(u32, @intCast(j));
            n += 1;
        }
        if (n == 0) return new_ty;
        const merged_sigs = self.store.appendSignatures(sig_buf[0..n]) catch return new_ty;
        for (0..n) |k| {
            if (self.sig_type_params.get(src_idx[k])) |prefix| {
                const dst = merged_sigs.start + @as(u32, @intCast(k));
                if (!self.sig_type_params.contains(dst)) {
                    const dup = self.gpa.dupe(u8, prefix) catch break;
                    self.sig_type_params.put(self.gpa, dst, dup) catch self.gpa.free(dup);
                }
            }
        }
        return self.store.add(.{ .kind = .function_t, .signatures = merged_sigs, .is_overload_set = true }) catch new_ty;
    }

    /// Build the INSTANCE type of a class — a record of fields and methods.
    /// Static members are not included (those live on the constructor).
    /// `extends ParentClass` contributes the parent's instance props so
    /// structural assignability (subclass → superclass) holds.
    fn buildClassInstanceType(self: *Checker, decl: NodeIndex, name: []const u8) TypeId {
        // Cycle break: if this class is already being built (reached via a
        // `this` annotation on one of its own members, or an inheritance
        // cycle), resolve to a `type_ref` by name rather than rebuilding it.
        for (self.building_classes[0..self.building_n]) |d| {
            if (d == decl) return self.store.typeRef(name, &.{}) catch tymod.ID_UNKNOWN;
        }
        if (self.building_n >= self.building_classes.len) {
            return self.store.typeRef(name, &.{}) catch tymod.ID_UNKNOWN;
        }
        self.building_classes[self.building_n] = decl;
        self.building_n += 1;
        defer self.building_n -= 1;

        const data = self.ast_ref.nodeData(decl);
        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(data.lhs));
        var props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer props.deinit(self.gpa);
        // Direct base type — the `extends` superclass, recorded as a type_ref so
        // the facade's getBaseTypes/matchesTypeOrBaseType can walk the hierarchy
        // (restrict-template-expressions' `allow: {from:'file', name:'Base'}`).
        var base_buf: [1]TypeId = undefined;
        var base_n: usize = 0;
        // Inherit instance props through the full superclass chain.
        if (cd.super_class != .none) {
            var sc = cd.super_class;
            while (self.ast_ref.nodeTag(sc) == .grouping_expr or
                self.ast_ref.nodeTag(sc) == .ts_instantiation_expr)
            {
                sc = self.ast_ref.nodeData(sc).lhs;
            }
            var inherited = false;
            if (self.ast_ref.nodeTag(sc) == .identifier) {
                const parent_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(sc));
                if (self.store.typeRef(parent_name, &.{})) |br| {
                    base_buf[0] = br;
                    base_n = 1;
                } else |_| {}
                var seen: [8][]const u8 = undefined;
                var seen_n: u8 = 0;
                self.flattenInheritedProps(parent_name, 0, &seen, &seen_n, &props);
                inherited = props.items.len > 0;
            }
            // Couldn't resolve the parent's structural shape (e.g. extends a
            // value of constructor type like `Constructable<X>`).  Be
            // conservative and synthesize a `toString` prop so consumers
            // treating its presence as "user-defined string coercion" don't
            // mis-classify the instance as un-coerced.
            if (!inherited) {
                props.append(self.gpa, .{ .name = "toString", .type_id = tymod.ID_ANY }) catch {};
            }
        }
        const base_list = if (base_n == 0) tymod.TypeIdList.empty else (self.store.appendTypeIds(base_buf[0..base_n]) catch tymod.TypeIdList.empty);
        if (cd.body == .none) {
            const list = self.store.appendObjectProps(props.items) catch return tymod.ID_UNKNOWN;
            return self.store.add(.{ .kind = .object_t, .object_props = list, .name = name, .list_data = base_list }) catch tymod.ID_UNKNOWN;
        }
        const body_data = self.ast_ref.nodeData(cd.body);
        const slice = self.directRange(body_data.lhs, body_data.rhs) orelse {
            const list = self.store.appendObjectProps(props.items) catch return tymod.ID_UNKNOWN;
            return self.store.add(.{ .kind = .object_t, .object_props = list, .name = name, .list_data = base_list }) catch tymod.ID_UNKNOWN;
        };
        // Pre-scan: find instance method names that have overload sigs (no body).
        // They will be merged into multi-sig types; their implementations are skipped.
        var overload_names_buf: [16][]const u8 = undefined;
        var overload_count: usize = 0;
        for (slice) |raw| {
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) != .method_def) continue;
            if (self.classMemberIsStatic(m)) continue;
            const mdata = self.ast_ref.nodeData(m);
            if (mdata.lhs == .none or mdata.rhs == .none) continue;
            const ktag = self.ast_ref.nodeTag(mdata.lhs);
            if (ktag != .identifier and ktag != .property_ident) continue;
            const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(mdata.rhs));
            if (md.body != .none) continue;
            const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
            var already = false;
            for (overload_names_buf[0..overload_count]) |n| {
                if (std.mem.eql(u8, n, key)) { already = true; break; }
            }
            if (!already and overload_count < overload_names_buf.len) {
                overload_names_buf[overload_count] = key;
                overload_count += 1;
            }
        }
        for (slice) |raw| {
            const member: NodeIndex = @enumFromInt(raw);
            const mtag = self.ast_ref.nodeTag(member);
            // For method_def with overloads: merge no-body sigs, skip implementation.
            if (mtag == .method_def and !self.classMemberIsStatic(member)) {
                const mdata = self.ast_ref.nodeData(member);
                if (mdata.lhs != .none and mdata.rhs != .none) {
                    const ktag = self.ast_ref.nodeTag(mdata.lhs);
                    if (ktag == .identifier or ktag == .property_ident) {
                        const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
                        const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(mdata.rhs));
                        var has_overloads = false;
                        for (overload_names_buf[0..overload_count]) |n| {
                            if (std.mem.eql(u8, n, key)) { has_overloads = true; break; }
                        }
                        if (has_overloads) {
                            if (md.body != .none) continue; // implementation hidden by overloads
                            const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                            const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                            const new_ty = self.buildFunctionType(md.params_start, md.params_end, md.return_type, .none, is_async, is_generator);
                            if (md.type_params < md.type_params_end)
                                self.registerFnTypeParams(new_ty, md.type_params, md.type_params_end);
                            var found_existing = false;
                            for (props.items) |*existing| {
                                if (std.mem.eql(u8, existing.name, key)) {
                                    existing.type_id = self.mergeFunctionTypes(existing.type_id, new_ty);
                                    found_existing = true;
                                    break;
                                }
                            }
                            if (!found_existing) {
                                props.append(self.gpa, .{ .name = key, .type_id = new_ty, .is_method = true }) catch {};
                            }
                            continue;
                        }
                    }
                }
            }
            if (self.classMemberToProp(member, false)) |p| {
                // Inherited prop with the same name is overridden by the
                // subclass definition — remove the prior entry.
                var k: usize = 0;
                while (k < props.items.len) : (k += 1) {
                    if (std.mem.eql(u8, props.items[k].name, p.name)) {
                        _ = props.orderedRemove(k);
                        break;
                    }
                }
                props.append(self.gpa, p) catch {};
            }
        }
        // Constructor parameter properties: `constructor(readonly x: T)` makes `x` a
        // class property.  Add them before the interface-merge pass so the property
        // is visible when later code resolves `this.x`.
        // Note: a constructor WITH a body is emitted as method_def (key = "constructor"),
        // not constructor_def (which is for declare/overload-only constructors).
        for (slice) |raw| {
            const member: NodeIndex = @enumFromInt(raw);
            const mtag = self.ast_ref.nodeTag(member);
            if (mtag != .method_def and mtag != .constructor_def) continue;
            const ctor_data = self.ast_ref.nodeData(member);
            // method_def / constructor_def: lhs = key, rhs = extra index to MethodData
            // For constructor_def the key may be .none; for method_def check the key name.
            if (mtag == .method_def) {
                if (ctor_data.lhs == .none) continue;
                const key_tag = self.ast_ref.nodeTag(ctor_data.lhs);
                if (key_tag != .identifier and key_tag != .property_ident) continue;
                const key_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ctor_data.lhs));
                if (!std.mem.eql(u8, key_name, "constructor")) continue;
            }
            if (ctor_data.rhs == .none) continue;
            const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(ctor_data.rhs));
            if (md.params_start >= md.params_end) continue;
            const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
            if (md.params_end > ext_len) continue;
            for (self.ast_ref.extra_data[md.params_start..md.params_end]) |param_raw| {
                const param: NodeIndex = @enumFromInt(param_raw);
                if (self.ast_ref.nodeTag(param) != .ts_parameter_property) continue;
                var binding = self.ast_ref.nodeData(param).lhs;
                if (binding == .none) continue;
                if (self.ast_ref.nodeTag(binding) == .assignment_pattern) {
                    binding = self.ast_ref.nodeData(binding).lhs;
                }
                if (self.ast_ref.nodeTag(binding) != .identifier) continue;
                const prop_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(binding));
                if (prop_name.len == 0) continue;
                const prop_ty = self.paramDeclaredType(param);
                // Only add if not already present (explicit property_def takes precedence).
                var already = false;
                for (props.items) |existing| {
                    if (std.mem.eql(u8, existing.name, prop_name)) { already = true; break; }
                }
                if (!already) props.append(self.gpa, .{ .name = prop_name, .type_id = prop_ty }) catch {};
            }
            break; // only one constructor
        }
        // Declaration merging: merge members from any same-named interface declarations.
        for (self.merged_iface_extra.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const extra_data = self.ast_ref.nodeData(entry.node);
            const extra_id = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(extra_data.lhs));
            if (extra_id.body_end > extra_id.body_start) {
                const extra_body = self.ast_ref.extra_data[extra_id.body_start..extra_id.body_end];
                for (extra_body) |raw| {
                    const member: NodeIndex = @enumFromInt(raw);
                    if (self.interfaceMemberToProp(member)) |p| {
                        props.append(self.gpa, p) catch {};
                    }
                }
            }
        }
        const list = self.store.appendObjectProps(props.items) catch return tymod.ID_UNKNOWN;
        return self.store.add(.{ .kind = .object_t, .object_props = list, .name = name, .list_data = base_list }) catch tymod.ID_UNKNOWN;
    }

    /// True when a class member (property/method/getter/setter) carries the
    /// `static` modifier.  PropertyData carries no modifier bits, so detect it
    /// by scanning the leading modifier tokens before the member's main token
    /// (mirrors the estree adapter's `_methodFlags`).
    fn classMemberIsStatic(self: *Checker, member: NodeIndex) bool {
        const token_tags = self.ast_ref.tokens.items(.tag);
        const main_tok = self.ast_ref.nodeMainToken(member);
        var i: usize = @intCast(main_tok);
        if (i >= token_tags.len) return false;
        if (token_tags[i] == .kw_static) return true;
        var steps: u8 = 0;
        while (i > 0 and steps < 8) : (steps += 1) {
            i -= 1;
            switch (token_tags[i]) {
                .kw_static => return true,
                // Other leading member modifiers — keep scanning past them.
                .kw_async, .asterisk, .kw_readonly, .kw_override, .kw_abstract,
                .kw_declare, .kw_get, .kw_set => continue,
                // TS accessibility / accessor modifiers tokenize as identifiers.
                .identifier => {
                    const txt = self.ast_ref.tokenText(@intCast(i));
                    if (std.mem.eql(u8, txt, "public") or std.mem.eql(u8, txt, "private") or
                        std.mem.eql(u8, txt, "protected") or std.mem.eql(u8, txt, "accessor"))
                        continue;
                    return false;
                },
                else => return false,
            }
        }
        return false;
    }

    /// Build the *static side* of a class — an object type holding the
    /// `static` fields/methods/getters keyed by name.  This is the type of the
    /// class *value* (`Foo` referenced directly, e.g. `setTimeout(Foo.fn)`),
    /// distinct from the instance type produced by `new Foo()`.  Construction
    /// itself flows through `newExprInstanceType`, so omitting a construct
    /// signature here is fine.
    pub fn buildClassStaticType(self: *Checker, decl: NodeIndex, name: []const u8) TypeId {
        // Same cycle break as buildClassInstanceType: a static initializer that
        // references the class's own static side (`static bar = A.foo`) must not
        // rebuild the static type re-entrantly.
        for (self.building_classes[0..self.building_n]) |d| {
            if (d == decl) return self.store.typeRef(name, &.{}) catch tymod.ID_UNKNOWN;
        }
        if (self.building_n >= self.building_classes.len) {
            return self.store.typeRef(name, &.{}) catch tymod.ID_UNKNOWN;
        }
        self.building_classes[self.building_n] = decl;
        self.building_n += 1;
        defer self.building_n -= 1;

        const data = self.ast_ref.nodeData(decl);
        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(data.lhs));
        if (cd.body == .none) return tymod.ID_UNKNOWN;
        const body_data = self.ast_ref.nodeData(cd.body);
        const slice = self.directRange(body_data.lhs, body_data.rhs) orelse return tymod.ID_UNKNOWN;
        var props: std.ArrayList(tymod.ObjectProp) = .empty;
        defer props.deinit(self.gpa);
        // Pre-scan: find static method names that have overload sigs (no body).
        var st_overload_names_buf: [16][]const u8 = undefined;
        var st_overload_count: usize = 0;
        for (slice) |raw| {
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) != .method_def) continue;
            if (!self.classMemberIsStatic(m)) continue;
            const mdata = self.ast_ref.nodeData(m);
            if (mdata.lhs == .none or mdata.rhs == .none) continue;
            const ktag = self.ast_ref.nodeTag(mdata.lhs);
            if (ktag != .identifier and ktag != .property_ident) continue;
            const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(mdata.rhs));
            if (md.body != .none) continue;
            const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
            var already = false;
            for (st_overload_names_buf[0..st_overload_count]) |n| {
                if (std.mem.eql(u8, n, key)) { already = true; break; }
            }
            if (!already and st_overload_count < st_overload_names_buf.len) {
                st_overload_names_buf[st_overload_count] = key;
                st_overload_count += 1;
            }
        }
        for (slice) |raw| {
            const member: NodeIndex = @enumFromInt(raw);
            const mtag = self.ast_ref.nodeTag(member);
            if (mtag == .method_def and self.classMemberIsStatic(member)) {
                const mdata = self.ast_ref.nodeData(member);
                if (mdata.lhs != .none and mdata.rhs != .none) {
                    const ktag = self.ast_ref.nodeTag(mdata.lhs);
                    if (ktag == .identifier or ktag == .property_ident) {
                        const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
                        const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(mdata.rhs));
                        var has_overloads = false;
                        for (st_overload_names_buf[0..st_overload_count]) |n| {
                            if (std.mem.eql(u8, n, key)) { has_overloads = true; break; }
                        }
                        if (has_overloads) {
                            if (md.body != .none) continue;
                            const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                            const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                            const new_ty = self.buildFunctionType(md.params_start, md.params_end, md.return_type, .none, is_async, is_generator);
                            if (md.type_params < md.type_params_end)
                                self.registerFnTypeParams(new_ty, md.type_params, md.type_params_end);
                            var found_existing = false;
                            for (props.items) |*existing| {
                                if (std.mem.eql(u8, existing.name, key)) {
                                    existing.type_id = self.mergeFunctionTypes(existing.type_id, new_ty);
                                    found_existing = true;
                                    break;
                                }
                            }
                            if (!found_existing) {
                                props.append(self.gpa, .{ .name = key, .type_id = new_ty, .is_method = true, .is_static = true }) catch {};
                            }
                            continue;
                        }
                    }
                }
            }
            if (self.classMemberToProp(member, true)) |p| {
                var sp = p;
                sp.is_static = true;
                var k: usize = 0;
                while (k < props.items.len) : (k += 1) {
                    if (std.mem.eql(u8, props.items[k].name, sp.name)) {
                        _ = props.orderedRemove(k);
                        break;
                    }
                }
                props.append(self.gpa, sp) catch {};
            }
        }
        if (props.items.len == 0) return tymod.ID_UNKNOWN;
        const list = self.store.appendObjectProps(props.items) catch return tymod.ID_UNKNOWN;
        // alias_name="__static__" marks this as a class static (constructor) type so
        // the JS facade can surface objectFlags.Anonymous (16) instead of Interface (2),
        // allowing prefer-readonly's getTypeToClassRelation to return Class (not Instance).
        return self.store.add(.{ .kind = .object_t, .object_props = list, .name = name, .alias_name = "__static__" }) catch tymod.ID_UNKNOWN;
    }

    fn classMemberToProp(self: *Checker, member: NodeIndex, want_static: bool) ?tymod.ObjectProp {
        const tag = self.ast_ref.nodeTag(member);
        const data = self.ast_ref.nodeData(member);
        // Static members live on the constructor (static side); instance
        // members on the prototype.  Route each to the matching object type.
        if (self.classMemberIsStatic(member) != want_static) return null;
        switch (tag) {
            .property_def => {
                // lhs = key, rhs = extra index to PropertyData
                if (data.lhs == .none) return null;
                if (self.ast_ref.nodeTag(data.lhs) != .identifier and
                    self.ast_ref.nodeTag(data.lhs) != .property_ident) return null;
                const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(data.lhs));
                const pd = self.ast_ref.extraData(ast.PropertyData, @intFromEnum(data.rhs));
                var ty: TypeId = tymod.ID_UNKNOWN;
                if (pd.type_annotation != .none and
                    self.ast_ref.nodeTag(pd.type_annotation) == .ts_type_annotation)
                {
                    const ty_node = self.ast_ref.nodeData(pd.type_annotation).lhs;
                    ty = self.resolveTypeNode(ty_node);
                } else if (pd.value != .none) {
                    const raw = self.typeOf(pd.value);
                    const t = self.store.get(raw);
                    // Class properties without explicit type annotations are widened
                    // from literal types to their base types, like let declarations.
                    // Enum members widen to the enum type (`p1 = E.B` → E).
                    if (t.enum_name.len > 0 and self.enumInitIsFresh(pd.value, 0)) {
                        ty = self.buildEnumUnionType(t.enum_name) orelse raw;
                    } else ty = switch (t.kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        .bigint_literal => tymod.ID_BIGINT,
                        else => raw,
                    };
                }
                // A class field whose initializer is a regular
                // `function () {}` is a method that uses `this`.  Mark
                // it so unbound-method fires on `instance.field`.  Arrow
                // functions don't bind `this`, so they don't qualify.
                const is_method_like = if (pd.value != .none) blk: {
                    const vt = self.ast_ref.nodeTag(pd.value);
                    break :blk vt == .fn_expr or vt == .async_fn_expr or
                        vt == .generator_fn_expr or vt == .async_generator_fn_expr;
                } else false;
                return .{ .name = name, .type_id = ty, .is_method = is_method_like, .is_fn_property = is_method_like };
            },
            .method_def, .getter_def, .setter_def => {
                if (data.lhs == .none) return null;
                if (self.ast_ref.nodeTag(data.lhs) != .identifier and
                    self.ast_ref.nodeTag(data.lhs) != .property_ident) return null;
                const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(data.lhs));
                const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(data.rhs));
                const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                // Getter: the property value IS the return type, not the function itself.
                if (tag == .getter_def) {
                    const fn_ty = self.buildFunctionType(md.params_start, md.params_end, md.return_type, md.body, is_async, is_generator);
                    const ft = self.store.get(fn_ty);
                    if (ft.kind == .function_t) {
                        const sigs = self.store.signaturesOf(ft.signatures);
                        if (sigs.len > 0) {
                            return .{ .name = name, .type_id = sigs[0].return_type };
                        }
                    }
                    return .{ .name = name, .type_id = tymod.ID_ANY };
                }
                // Setter: the property value type comes from the first parameter
                // when annotated, otherwise from the paired getter's return type.
                if (tag == .setter_def) {
                    const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
                    if (md.params_start < md.params_end and md.params_end <= ext_len) {
                        const param: NodeIndex = @enumFromInt(self.ast_ref.extra_data[md.params_start]);
                        if (self.paramHasAnnotation(param)) {
                            const pty = self.paramDeclaredType(param);
                            if (!pty.eq(tymod.ID_UNKNOWN)) return .{ .name = name, .type_id = pty };
                        }
                    }
                    if (self.pairedGetterReturnType(member, name)) |t|
                        return .{ .name = name, .type_id = t };
                    return .{ .name = name, .type_id = tymod.ID_ANY };
                }
                const fn_ty = self.buildFunctionType(
                    md.params_start,
                    md.params_end,
                    md.return_type,
                    md.body,
                    is_async,
                    is_generator,
                );
                if (md.type_params < md.type_params_end)
                    self.registerFnTypeParams(fn_ty, md.type_params, md.type_params_end);
                return .{
                    .name = name,
                    .type_id = fn_ty,
                    .is_method = true,
                };
            },
            else => return null,
        }
    }

    fn firstTypeArg(self: *Checker, ref_node: NodeIndex) NodeIndex {
        const data = self.ast_ref.nodeData(ref_node);
        const range = self.safeSubRange(data.rhs) orelse return .none;
        if (range.end <= range.start) return .none;
        const idx = self.ast_ref.extra_data[range.start];
        return @enumFromInt(idx);
    }

    fn collectTypeArgs(self: *Checker, ref_node: NodeIndex, buf: []TypeId) []TypeId {
        const data = self.ast_ref.nodeData(ref_node);
        const range = self.safeSubRange(data.rhs) orelse return buf[0..0];
        const slice = self.ast_ref.extra_data[range.start..range.end];
        const n = @min(slice.len, buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const arg_node: NodeIndex = @enumFromInt(slice[i]);
            buf[i] = self.resolveTypeNode(arg_node);
        }
        return buf[0..n];
    }

    /// Like collectTypeArgs but preserves in-scope type parameters as
    /// type_param TypeIds instead of widening them to their constraints.
    fn collectTypeArgsParamAware(self: *Checker, ref_node: NodeIndex, buf: []TypeId) []TypeId {
        const data = self.ast_ref.nodeData(ref_node);
        const range = self.safeSubRange(data.rhs) orelse return buf[0..0];
        const slice = self.ast_ref.extra_data[range.start..range.end];
        const n = @min(slice.len, buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const arg_node: NodeIndex = @enumFromInt(slice[i]);
            buf[i] = self.resolveTypeNodeParamAware(arg_node);
        }
        return buf[0..n];
    }

    fn resolveUnion(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        var buf: [16]TypeId = undefined;
        const n = @min(slice.len, buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const m: NodeIndex = @enumFromInt(slice[i]);
            buf[i] = self.resolveTypeNode(m);
        }
        return self.store.unionOf(buf[0..n]) catch tymod.ID_UNKNOWN;
    }

    fn resolveTupleType(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        var buf: [16]TypeId = undefined;
        const n = @min(slice.len, buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const m: NodeIndex = @enumFromInt(slice[i]);
            if (self.ast_ref.nodeTag(m) == .spread_element) {
                // Rest element in tuple type: `...T[]` — resolve inner type and wrap.
                const inner = self.resolveTypeNode(self.ast_ref.nodeData(m).lhs);
                buf[i] = self.store.restOf(inner) catch tymod.ID_ANY;
            } else {
                buf[i] = self.resolveTypeNode(m);
            }
        }
        const list = self.store.appendTypeIds(buf[0..n]) catch return tymod.ID_UNKNOWN;
        return self.store.add(.{ .kind = .tuple_t, .list_data = list }) catch tymod.ID_UNKNOWN;
    }

    /// Unwrap a `rest_t` tuple element to its usable element type.
    /// `rest_t(array_t(T))` → T;  `rest_t(T)` → T;  anything else → id.
    fn peelRestElem(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .rest_t) return id;
        const inner_ids = self.store.idsOf(t.list_data);
        if (inner_ids.len == 0) return tymod.ID_ANY;
        const inner = inner_ids[0];
        const it = self.store.get(inner);
        if (it.kind == .array_t or it.kind == .readonly_array_t) {
            const elem_ids = self.store.idsOf(it.list_data);
            return if (elem_ids.len > 0) elem_ids[0] else tymod.ID_ANY;
        }
        return inner;
    }

    fn resolveIntersection(self: *Checker, ty_node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(ty_node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        var buf: [16]TypeId = undefined;
        const n = @min(slice.len, buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const m: NodeIndex = @enumFromInt(slice[i]);
            buf[i] = self.resolveTypeNode(m);
        }
        // Incompatible primitive intersection → never (`string & number`); a
        // union member distributes (`(A|B) & C` → `(A&C) | (B&C)`).
        return self.buildIntersection(buf[0..n]);
    }

    fn intersectionIsImpossible(store: *const tymod.TypeStore, members: []const TypeId) bool {
        var saw_string = false;
        var saw_number = false;
        var saw_boolean = false;
        var saw_bigint = false;
        for (members) |m| {
            const t = store.get(m);
            switch (t.kind) {
                .string, .string_literal => saw_string = true,
                .number, .number_literal => saw_number = true,
                .boolean, .boolean_literal => saw_boolean = true,
                .bigint, .bigint_literal => saw_bigint = true,
                else => {},
            }
        }
        // Any two-of-four primitive families together → impossible.
        var count: u32 = 0;
        if (saw_string) count += 1;
        if (saw_number) count += 1;
        if (saw_boolean) count += 1;
        if (saw_bigint) count += 1;
        return count >= 2;
    }

    /// Build an intersection, distributing over any union members so the result
    /// matches TS normalization: `(A|B) & C` → `(A&C) | (B&C)`.  This keeps each
    /// branch's primitive constituents directly reachable (a union member of an
    /// intersection carries the `Union` flag, not `StringLike`, hiding the
    /// falsy-capable `string` from no-unnecessary-condition's isPossiblyFalsy).
    /// Impossible combos collapse to `never` and drop out; an explosion of
    /// combinations falls back to the flat (undistributed) intersection.
    fn buildIntersection(self: *Checker, members: []const TypeId) TypeId {
        var has_union = false;
        var total: usize = 1;
        for (members) |m| {
            const t = self.store.get(m);
            if (t.kind == .union_t) {
                has_union = true;
                // Bounded: once we pass the cap we stop accumulating, so a large
                // union can't overflow `total` before the >64 fallback fires.
                if (total <= 64) total *= self.store.idsOf(t.list_data).len;
            }
        }
        // No union to distribute, or too many combinations → flat intersection.
        if (!has_union or total > 64) {
            if (intersectionIsImpossible(&self.store, members)) return tymod.ID_NEVER;
            return self.store.intersectionOf(members) catch tymod.ID_UNKNOWN;
        }
        var combo_buf: [64]TypeId = undefined; // resulting union members
        var combo_n: usize = 0;
        var part_buf: [16]TypeId = undefined; // one combination's intersection members
        var idx_buf: [16]usize = undefined; // odometer over union indices
        @memset(&idx_buf, 0);
        const mn = @min(members.len, idx_buf.len);
        while (true) {
            // Build this combination: pick idx_buf[mi] from each union member,
            // pass non-union members through.
            var pn: usize = 0;
            for (members[0..mn], 0..) |m, mi| {
                const t = self.store.get(m);
                const pick = if (t.kind == .union_t) self.store.idsOf(t.list_data)[idx_buf[mi]] else m;
                if (pn < part_buf.len) {
                    part_buf[pn] = pick;
                    pn += 1;
                }
            }
            // intersectionOf flattens nested intersections and returns `never`
            // for an incompatible combo (e.g. `number & "foo"`); drop those.
            const combo_ty = self.store.intersectionOf(part_buf[0..pn]) catch tymod.ID_UNKNOWN;
            if (!combo_ty.eq(tymod.ID_NEVER) and combo_n < combo_buf.len) {
                combo_buf[combo_n] = combo_ty;
                combo_n += 1;
            }
            // Odometer increment: advance the rightmost union member, carrying left.
            var k: usize = mn;
            var advanced = false;
            while (k > 0) {
                k -= 1;
                const t = self.store.get(members[k]);
                if (t.kind != .union_t) continue;
                const ulen = self.store.idsOf(t.list_data).len;
                idx_buf[k] += 1;
                if (idx_buf[k] < ulen) {
                    advanced = true;
                    break;
                }
                idx_buf[k] = 0;
            }
            if (!advanced) break;
        }
        if (combo_n == 0) return tymod.ID_NEVER;
        if (combo_n == 1) return combo_buf[0];
        return self.store.unionOf(combo_buf[0..combo_n]) catch tymod.ID_UNKNOWN;
    }

    // ── Expression helpers ────────────────────────────────

    fn inferAsCast(self: *Checker, node: NodeIndex, tag: ast.Node.Tag) TypeId {
        const data = self.ast_ref.nodeData(node);
        const ty_node = if (tag == .ts_as_expr) data.rhs else data.lhs;
        const inner_node = if (tag == .ts_as_expr) data.lhs else data.rhs;
        // `as const`: TS-specific syntax that converts literals to their
        // narrowest readonly form.  Parses as a type reference to `const`.
        // For an array literal source we synthesize a tuple_t with each
        // element's specific type — this lets spread-of-tuple checks see
        // per-position any in `['a', 1 as any] as const`.
        if (ty_node != .none and self.ast_ref.nodeTag(ty_node) == .ts_type_reference) {
            const name_tok = self.ast_ref.nodeMainToken(ty_node);
            const name = self.ast_ref.tokenText(name_tok);
            if (std.mem.eql(u8, name, "const")) {
                return self.inferAsConst(inner_node);
            }
        }
        return self.resolveTypeNode(ty_node);
    }

    /// `as const` lowering: build the narrowest readonly type for the source.
    /// - array_literal  → readonly tuple with per-element literal types
    /// - object_literal → object with all properties readonly and literal-typed
    /// - anything else  → typeOf(src) unchanged
    fn inferAsConst(self: *Checker, src: NodeIndex) TypeId {
        if (src == .none) return tymod.ID_UNKNOWN;
        const src_tag = self.ast_ref.nodeTag(src);
        if (src_tag == .array_literal) {
            const data = self.ast_ref.nodeData(src);
            const empty_slice: []const u32 = &.{};
            const slice: []const u32 = self.directRange(data.lhs, data.rhs) orelse empty_slice;
            var buf: [32]TypeId = undefined;
            const n = @min(slice.len, buf.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const elem: NodeIndex = @enumFromInt(slice[i]);
                buf[i] = if (elem == .none) tymod.ID_UNDEFINED else self.inferAsConst(elem);
            }
            const list = self.store.appendTypeIds(buf[0..n]) catch return tymod.ID_UNKNOWN;
            return self.store.add(.{ .kind = .tuple_t, .list_data = list, .name = "readonly" }) catch tymod.ID_UNKNOWN;
        }
        if (src_tag == .object_literal) {
            const data = self.ast_ref.nodeData(src);
            const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
            var props_buf: [16]tymod.ObjectProp = undefined;
            var n: usize = 0;
            for (slice) |raw| {
                if (n >= props_buf.len) break;
                const p: NodeIndex = @enumFromInt(raw);
                const pt = self.ast_ref.nodeTag(p);
                switch (pt) {
                    .property => {
                        const pd = self.ast_ref.nodeData(p);
                        const key_name = self.staticPropertyKey(pd.lhs) orelse return tymod.ID_UNKNOWN;
                        const val_ty = self.inferAsConst(pd.rhs);
                        props_buf[n] = .{ .name = key_name, .type_id = val_ty, .readonly = true };
                        n += 1;
                    },
                    .shorthand_property => {
                        const pd = self.ast_ref.nodeData(p);
                        const key_name = self.staticPropertyKey(pd.lhs) orelse return tymod.ID_UNKNOWN;
                        const val_ty = self.typeOf(pd.lhs);
                        props_buf[n] = .{ .name = key_name, .type_id = val_ty, .readonly = true };
                        n += 1;
                    },
                    else => return tymod.ID_UNKNOWN,
                }
            }
            return self.store.objectOf(props_buf[0..n]) catch tymod.ID_UNKNOWN;
        }
        return self.typeOf(src);
    }

    fn inferSatisfies(self: *Checker, node: NodeIndex) TypeId {
        // `x satisfies T` leaves the type of x unchanged.
        return self.typeOf(self.ast_ref.nodeData(node).lhs);
    }

    fn inferSequence(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        const range = self.safeSubRange(data.lhs) orelse return tymod.ID_UNDEFINED;
        if (range.end <= range.start) return tymod.ID_UNDEFINED;
        // A sequence expression should have at least 2 elements (comma operator).
        // If there's only 1 element (e.g., `(NUMBER, )` with missing second operand),
        // the result type is `any` to represent the syntax error / missing operand.
        const num_elements = range.end - range.start;
        if (num_elements < 2) return tymod.ID_ANY;
        const last_idx = self.ast_ref.extra_data[range.end - 1]; // zbc-disable-line: index-minus-one-without-zero-guard
        if (last_idx == @intFromEnum(NodeIndex.none)) return tymod.ID_ANY;
        return self.typeOf(@enumFromInt(last_idx));
    }

    fn inferConditional(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        const cond_data = self.ast_ref.extraData(ast.Conditional, @intFromEnum(data.rhs));
        const a = self.typeOf(cond_data.consequent);
        const b = self.typeOf(cond_data.alternate);
        return self.store.unionOf(&.{ a, b }) catch tymod.ID_ANY;
    }

    fn inferLogical(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        const a = self.typeOf(data.lhs);
        const b = self.typeOf(data.rhs);
        const tag = self.ast_ref.nodeTag(node);
        // `a ?? b` evaluates to a (when non-nullish) or b — the result
        // type is `(a - null - undefined) | b`.  Stripping nullish from
        // the LHS catches `x?: true; x ?? true` → `true`.  When the LHS's
        // nullishness is statically known the unused branch is unreachable
        // (control-flow narrowing): a never-nullish `a` ⇒ `a`; an always-nullish
        // `a` ⇒ `b`.
        if (tag == .nullish_coalesce) {
            if (self.neverNullish(a)) return a;
            if (self.alwaysNullish(a)) return b;
            const a_stripped = self.stripNullishUnion(a);
            return self.store.unionOf(&.{ a_stripped, b }) catch tymod.ID_ANY;
        }
        // `a || b` evaluates to `a` when truthy, else `b` — so the result type
        // drops the falsy part of the LHS. We strip null/undefined (the part that
        // matters for nullability), matching TS: `(string|null) || 'a'` is
        // `string | 'a'`, not nullish (prefer-optional-chain's requireNullish).
        // A statically-truthy LHS short-circuits to `a` (RHS unreachable); a
        // statically-falsy LHS evaluates to `b`.
        if (tag == .logical_or) {
            // A constructor result (`new X()`) is always a fresh object → truthy,
            // even when X's instance type is a named lib ref (Error/URL/…) that
            // alwaysTruthy can't see through. `new Error() || 'x'` is `Error`.
            if (self.ast_ref.nodeTag(data.lhs) == .new_expr) return a;
            if (self.alwaysTruthy(a)) return a;
            if (self.alwaysFalsy(a)) return b;
            const a_stripped = self.stripNullishUnion(a);
            return self.store.unionOf(&.{ a_stripped, b }) catch tymod.ID_ANY;
        }
        // `a && b` evaluates to `a` when falsy, else `b`.  A statically-falsy LHS
        // short-circuits to `a` (RHS unreachable — `false && p()` is just `false`,
        // not `false | Promise`); a statically-truthy LHS evaluates to `b`.
        // `any && b` → `any`; tsc propagates `any` through logical operators.
        if (tymod.isAny(&self.store, a)) return a;
        if (self.alwaysFalsy(a)) return a;
        if (self.alwaysTruthy(a)) return b;
        // For `a && b`, narrow b by the condition a and return false | narrowed_b
        const narrowed_b = self.tryNarrowExprByCondition(data.lhs, data.rhs, b) orelse b;
        const false_literal = self.store.booleanLiteral(false) catch tymod.ID_BOOLEAN;
        return self.store.unionOf(&.{ false_literal, narrowed_b }) catch tymod.ID_ANY;
    }

    /// Try to narrow an expression's type based on a condition in a logical AND.
    fn tryNarrowExprByCondition(self: *Checker, cond_node: NodeIndex, expr_node: NodeIndex, expr_type: TypeId) ?TypeId {
        // Handle typeof checks: typeof x === "string" narrows x
        if (self.ast_ref.nodeTag(cond_node) == .strict_equal or self.ast_ref.nodeTag(cond_node) == .equal) {
            const cond_data = self.ast_ref.nodeData(cond_node);
            // Check typeof lhs === string_literal rhs
            if (self.ast_ref.nodeTag(cond_data.lhs) == .typeof_expr) {
                const typeof_node = cond_data.lhs;
                const typeof_operand = self.ast_ref.nodeData(typeof_node).lhs;
                if (self.nodesSyntacticallyEqual(typeof_operand, expr_node)) {
                    if (self.typeofStringValue(cond_data.rhs)) |narrowable| {
                        return self.intersectNarrow(expr_type, narrowable, true);
                    }
                }
            }
            // Check string_literal lhs === typeof rhs
            if (self.ast_ref.nodeTag(cond_data.rhs) == .typeof_expr) {
                const typeof_node = cond_data.rhs;
                const typeof_operand = self.ast_ref.nodeData(typeof_node).lhs;
                if (self.nodesSyntacticallyEqual(typeof_operand, expr_node)) {
                    if (self.typeofStringValue(cond_data.lhs)) |narrowable| {
                        return self.intersectNarrow(expr_type, narrowable, true);
                    }
                }
            }
        }
        return null;
    }

    /// Check if two AST nodes are syntactically equal.
    fn nodesSyntacticallyEqual(self: *Checker, a: NodeIndex, b: NodeIndex) bool {
        if (a == b) return true;
        if (a == .none or b == .none) return false;
        const tag_a = self.ast_ref.nodeTag(a);
        const tag_b = self.ast_ref.nodeTag(b);
        if (tag_a != tag_b) return false;
        const data_a = self.ast_ref.nodeData(a);
        const data_b = self.ast_ref.nodeData(b);
        return switch (tag_a) {
            .identifier => blk: {
                const tok_a = self.ast_ref.nodeMainToken(a);
                const tok_b = self.ast_ref.nodeMainToken(b);
                const name_a = self.ast_ref.tokenText(tok_a);
                const name_b = self.ast_ref.tokenText(tok_b);
                break :blk std.mem.eql(u8, name_a, name_b);
            },
            .this_expr => true,
            .member_expr, .optional_member_expr => blk: {
                const lhs_eq = self.nodesSyntacticallyEqual(data_a.lhs, data_b.lhs);
                if (!lhs_eq) break :blk false;
                const tok_a = self.ast_ref.nodeMainToken(data_a.rhs);
                const tok_b = self.ast_ref.nodeMainToken(data_b.rhs);
                const prop_a = self.ast_ref.tokenText(tok_a);
                const prop_b = self.ast_ref.tokenText(tok_b);
                break :blk std.mem.eql(u8, prop_a, prop_b);
            },
            .computed_member_expr, .optional_computed_member_expr => blk: {
                const lhs_eq = self.nodesSyntacticallyEqual(data_a.lhs, data_b.lhs);
                if (!lhs_eq) break :blk false;
                break :blk self.nodesSyntacticallyEqual(data_a.rhs, data_b.rhs);
            },
            else => false,
        };
    }

    /// A bigint literal whose textual value is zero (`0n` / `-0n`).
    fn isZeroBigint(s: []const u8) bool {
        return std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "0n") or
            std.mem.eql(u8, s, "-0") or std.mem.eql(u8, s, "-0n");
    }

    /// A type that can only ever be falsy at runtime — `false`, `0`, `0n`, `""`,
    /// `null`, `undefined`, `void`.  Lets `a && b` / `a || b` constant-fold the
    /// short-circuit (control-flow narrowing of the logical result).
    fn alwaysFalsy(self: *Checker, id: TypeId) bool {
        const t = self.store.get(id);
        return switch (t.kind) {
            .null_t, .undefined_t, .void_t => true,
            .boolean_literal => switch (t.literal_value) {
                .boolean => |v| v == false,
                else => false,
            },
            .number_literal => switch (t.literal_value) {
                .number => |v| v == 0,
                else => false,
            },
            .string_literal => switch (t.literal_value) {
                .string => |v| v.len == 0,
                else => false,
            },
            .bigint_literal => switch (t.literal_value) {
                .bigint => |v| isZeroBigint(v),
                else => false,
            },
            else => false,
        };
    }

    /// A type that can only ever be truthy at runtime — a `true`/non-zero/
    /// non-empty literal.  Conservative: composite types (object/function/array)
    /// are NOT folded here, to keep the blast radius to constant short-circuits.
    fn alwaysTruthy(self: *Checker, id: TypeId) bool {
        const t = self.store.get(id);
        return switch (t.kind) {
            .boolean_literal => switch (t.literal_value) {
                .boolean => |v| v == true,
                else => false,
            },
            .number_literal => switch (t.literal_value) {
                .number => |v| v != 0,
                else => false,
            },
            .string_literal => switch (t.literal_value) {
                .string => |v| v.len != 0,
                else => false,
            },
            .bigint_literal => switch (t.literal_value) {
                .bigint => |v| !isZeroBigint(v),
                else => false,
            },
            // Object-like types have no falsy values — always truthy
            // (`{a:1} || x` / `[1] || x` / `(()=>1) || x` are just the LHS).
            .object_t, .object_keyword, .array_t, .readonly_array_t, .tuple_t, .function_t => true,
            else => false,
        };
    }

    /// Broader truthiness check used only for the `!` operator.  Includes
    /// type_ref (class/interface instances) and union types where every member
    /// is always truthy.  NOT used for `&&`/`||` short-circuiting (too broad).
    fn alwaysTruthyForNot(self: *Checker, id: TypeId) bool {
        const t = self.store.get(id);
        if (t.kind == .type_ref) return true;
        if (t.kind == .union_t) {
            for (self.store.idsOf(t.list_data)) |mid| {
                if (!self.alwaysTruthyForNot(mid)) return false;
            }
            return true;
        }
        return self.alwaysTruthy(id);
    }

    /// Broader falsy check used for the `!` operator: includes union types where
    /// every member is always falsy.
    fn alwaysFalsyForNot(self: *Checker, id: TypeId) bool {
        const t = self.store.get(id);
        if (t.kind == .union_t) {
            for (self.store.idsOf(t.list_data)) |mid| {
                if (!self.alwaysFalsyForNot(mid)) return false;
            }
            return true;
        }
        return self.alwaysFalsy(id);
    }

    /// True when the named enum is a `const enum` — const enums preserve
    /// literal member types at use sites, non-const enums widen to the enum type.
    fn isConstEnum(self: *Checker, enum_name: []const u8) bool {
        const decl = self.type_decl_nodes.get(enum_name) orelse return false;
        if (self.ast_ref.nodeTag(decl) != .ts_enum_decl) return false;
        const enum_tok = self.ast_ref.nodeMainToken(decl);
        if (enum_tok == 0) return false;
        return self.ast_ref.tokenTag(enum_tok - 1) == .kw_const;
    }

    /// True when `id` provably has no null/undefined/void constituent (so the
    /// RHS of `a ?? b` is unreachable).  `any`/`unknown`/`error` could be
    /// nullish → not folded.
    fn neverNullish(self: *Checker, id: TypeId) bool {
        const t = self.store.get(id);
        return switch (t.kind) {
            .null_t, .undefined_t, .void_t, .any, .unknown, .error_t => false,
            .union_t => blk: {
                for (self.store.idsOf(t.list_data)) |m| {
                    switch (self.store.get(m).kind) {
                        .null_t, .undefined_t, .void_t, .any, .unknown, .error_t => break :blk false,
                        else => {},
                    }
                }
                break :blk true;
            },
            else => true,
        };
    }

    /// True when `id` is entirely null/undefined/void (so `a ?? b` is just `b`).
    fn alwaysNullish(self: *Checker, id: TypeId) bool {
        const t = self.store.get(id);
        return switch (t.kind) {
            .null_t, .undefined_t, .void_t => true,
            .union_t => blk: {
                const ids = self.store.idsOf(t.list_data);
                if (ids.len == 0) break :blk false;
                for (ids) |m| {
                    switch (self.store.get(m).kind) {
                        .null_t, .undefined_t, .void_t => {},
                        else => break :blk false,
                    }
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn stripNullishUnion(self: *Checker, id: TypeId) TypeId {
        const t = self.store.get(id);
        if (t.kind != .union_t) {
            if (t.kind == .null_t or t.kind == .undefined_t or t.kind == .void_t) return tymod.ID_NEVER;
            return id;
        }
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            const mk = self.store.get(m).kind;
            if (mk == .null_t or mk == .undefined_t or mk == .void_t) continue;
            if (n >= buf.len) return id;
            buf[n] = m;
            n += 1;
        }
        if (n == 0) return tymod.ID_NEVER;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch id;
    }

    fn inferCallReturn(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        const callee = data.lhs;
        if (callee == .none) return tymod.ID_UNKNOWN;
        // `Object.create(...)` is typed `any` by the lib — surface that so
        // no-unsafe-return / -assignment flag returning or assigning it.
        if (self.calleeIsObjectCreate(callee)) return tymod.ID_ANY;
        // `Promise.resolve<T>(...)` → `Promise<T>` (uses the explicit type arg) so
        // no-unsafe-return's Promise<any> detection fires.
        if (self.promiseResolveReturn(callee)) |ty| return ty;
        // `promise.then(onF?, onR?)` / `.catch(onR?)` / `.finally(cb?)` —
        // infer Promise<X> from the callback return type rather than always
        // returning Promise<unknown>.
        if (self.promiseThenCallReturn(node)) |ty| return ty;
        // `super()` calls the superclass constructor, which returns void.
        if (self.ast_ref.nodeTag(callee) == .super_expr) return tymod.ID_VOID;
        if (self.ast_ref.nodeTag(node) == .new_expr or
            self.calleeIsConstructible(callee))
        {
            // `new X<T>()` can parse as ts_instantiation_expr(new_expr, <T>) —
            // the type args live on the new_expr's PARENT, not its callee.
            // Resolve through the parent so `new Set<any>()` keeps its <any>.
            var inst_callee = callee;
            if (self.ast_ref.nodeTag(node) == .new_expr) {
                const parents = self.semantic.parent_indices;
                if (node.toInt() < parents.len) {
                    const par: NodeIndex = @enumFromInt(parents[node.toInt()]);
                    if (par != .none and self.ast_ref.nodeTag(par) == .ts_instantiation_expr)
                        inst_callee = par;
                }
            }
            if (self.newExprInstanceType(inst_callee)) |ty| return ty;
        }
        const callee_ty = self.typeOf(callee);
        if (tymod.isAny(&self.store, callee_ty)) return tymod.ID_ANY;
        const node_tag = self.ast_ref.nodeTag(node);
        const in_optional_chain = node_tag == .optional_call_expr or
            self.calleeIsInOptionalChain(callee);
        const lookup_ty = if (in_optional_chain) self.stripNullishForLookup(callee_ty) else callee_ty;
        const t = self.store.get(lookup_ty);
        const callee_unresolved = lookup_ty.eq(tymod.ID_UNKNOWN) or lookup_ty.eq(tymod.ID_ERROR);
        var result: TypeId = tymod.ID_UNKNOWN;
        if (t.kind == .function_t) {
            // Copy the SignatureList range (just two u32s) before any typeOf calls
            // that may grow signature_pool and invalidate a slice into it.
            const sig_range = t.signatures;
            const sig_count = sig_range.end - sig_range.start;
            if (sig_count > 0) {
                const best: usize = blk: {
                    if (sig_count == 1) break :blk 0;
                    const args_range = self.safeSubRange(data.rhs) orelse break :blk 0;
                    const extra = self.ast_ref.extra_data;
                    if (args_range.start > extra.len or args_range.end > extra.len) break :blk 0;
                    const args_slice = extra[args_range.start..args_range.end];
                    var arg_types_buf: [16]TypeId = undefined;
                    var argc: usize = 0;
                    for (args_slice) |raw| {
                        if (argc >= arg_types_buf.len) break;
                        arg_types_buf[argc] = self.typeOf(@enumFromInt(raw));
                        argc += 1;
                    }
                    // Re-fetch sigs after typeOf calls that may have reallocated the pool.
                    const sigs = self.store.signaturesOf(sig_range);
                    break :blk self.pickOverload(sigs, arg_types_buf[0..argc]);
                };
                const sigs = self.store.signaturesOf(sig_range);
                result = sigs[best].return_type;
            }
        }
        // Generic call-site inference — if the callee is a generic
        // function declaration in this file, infer its type parameters
        // from the argument types and substitute them into the
        // return.
        if (self.inferGenericReturn(callee, node, result)) |substituted| {
            result = substituted;
        }
        if (in_optional_chain and !result.eq(tymod.ID_UNKNOWN)) {
            if (self.typeContainsNullish(callee_ty) and !self.typeContainsUndefined(result)) {
                return self.store.unionOf(&.{ result, tymod.ID_UNDEFINED }) catch result;
            }
        }
        if (callee_unresolved and result.eq(tymod.ID_UNKNOWN)) return tymod.ID_ANY;
        return result;
    }

    /// True when `callee` is the member access `Object.create` (the global
    /// `Object`, dot-accessed `create`). Its lib return type is `any`.
    fn calleeIsObjectCreate(self: *Checker, callee: NodeIndex) bool {
        var n = callee;
        while (self.ast_ref.nodeTag(n) == .grouping_expr) n = self.ast_ref.nodeData(n).lhs;
        const tag = self.ast_ref.nodeTag(n);
        if (tag != .member_expr and tag != .optional_member_expr) return false;
        const d = self.ast_ref.nodeData(n);
        if (d.lhs == .none or d.rhs == .none) return false;
        if (self.ast_ref.nodeTag(d.lhs) != .identifier) return false;
        if (!std.mem.eql(u8, self.ast_ref.tokenText(self.ast_ref.nodeMainToken(d.lhs)), "Object")) return false;
        // Not a user-shadowed local `Object`.
        if (self.symbolForIdentRef(d.lhs) != null) return false;
        return std.mem.eql(u8, self.ast_ref.tokenText(self.ast_ref.nodeMainToken(d.rhs)), "create");
    }

    /// `Promise.resolve<T>(x)` → `Promise<T>` (the global `Promise`, dot-accessed
    /// `resolve`, using its explicit type argument). Returns null for any other
    /// callee. Lets no-unsafe-return flag returning `Promise.resolve<any>(…)`.
    fn promiseResolveReturn(self: *Checker, callee: NodeIndex) ?TypeId {
        var c = callee;
        var type_arg: NodeIndex = .none;
        if (self.ast_ref.nodeTag(c) == .ts_instantiation_expr) {
            const d = self.ast_ref.nodeData(c);
            c = d.lhs;
            if (d.rhs != .none) {
                const sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(d.rhs));
                if (sr.start < sr.end and sr.end <= self.ast_ref.extra_data.len)
                    type_arg = @enumFromInt(self.ast_ref.extra_data[sr.start]);
            }
        }
        while (self.ast_ref.nodeTag(c) == .grouping_expr) c = self.ast_ref.nodeData(c).lhs;
        const tag = self.ast_ref.nodeTag(c);
        if (tag != .member_expr and tag != .optional_member_expr) return null;
        const md = self.ast_ref.nodeData(c);
        if (md.lhs == .none or md.rhs == .none) return null;
        if (self.ast_ref.nodeTag(md.lhs) != .identifier) return null;
        if (!std.mem.eql(u8, self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.lhs)), "Promise")) return null;
        if (self.symbolForIdentRef(md.lhs) != null) return null; // user-shadowed local `Promise`
        // The static Promise producers — each returns a Promise so
        // no-floating-promises / no-misused-promises see a thenable result.
        //   resolve<T> → Promise<T>;  reject → Promise<never>;
        //   all/allSettled/race/any → Promise<unknown>.
        const method = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
        const inner: TypeId = if (std.mem.eql(u8, method, "resolve"))
            (if (type_arg != .none) self.resolveTypeNode(type_arg) else tymod.ID_UNKNOWN)
        else if (std.mem.eql(u8, method, "reject"))
            tymod.ID_NEVER
        else if (std.mem.eql(u8, method, "all") or std.mem.eql(u8, method, "allSettled") or
            std.mem.eql(u8, method, "race") or std.mem.eql(u8, method, "any"))
            tymod.ID_UNKNOWN
        else
            return null;
        return self.store.typeRef("Promise", &.{inner}) catch tymod.ID_UNKNOWN;
    }

    /// Infer the return type of `promise.then(onF?, onR?)`, `.catch(onR?)`,
    /// and `.finally(cb?)` from the supplied callback arguments.
    /// Returns null if the callee is not one of those methods on a Promise receiver.
    fn promiseThenCallReturn(self: *Checker, call_node: NodeIndex) ?TypeId {
        const data = self.ast_ref.nodeData(call_node);
        const callee = data.lhs;
        if (callee == .none) return null;

        var c = callee;
        while (self.ast_ref.nodeTag(c) == .grouping_expr) c = self.ast_ref.nodeData(c).lhs;

        const ctag = self.ast_ref.nodeTag(c);
        if (ctag != .member_expr and ctag != .optional_member_expr) return null;
        const md = self.ast_ref.nodeData(c);
        if (md.lhs == .none or md.rhs == .none) return null;

        const method = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.rhs));
        const is_then = std.mem.eql(u8, method, "then");
        const is_catch = std.mem.eql(u8, method, "catch");
        const is_finally = std.mem.eql(u8, method, "finally");
        if (!is_then and !is_catch and !is_finally) return null;

        // Receiver must be a concrete Promise<T>, not any/unknown.
        const recv_ty = self.typeOf(md.lhs);
        if (!tymod.isPromiseRef(&self.store, recv_ty)) return null;
        const recv_t = self.store.get(recv_ty);
        const recv_args = self.store.idsOf(recv_t.list_data);
        const T = if (recv_args.len > 0) recv_args[0] else tymod.ID_UNKNOWN;

        // .finally() always returns Promise<T>.
        if (is_finally) return self.store.typeRef("Promise", &.{T}) catch null;

        // Read call arguments.
        const args_range = self.safeSubRange(data.rhs) orelse {
            // No args: then()/catch() with no callback → Promise<T>.
            return self.store.typeRef("Promise", &.{T}) catch null;
        };
        const extra = self.ast_ref.extra_data;
        if (args_range.start > extra.len or args_range.end > extra.len) return null;
        const args = extra[args_range.start..args_range.end];

        if (is_then) {
            // TResult1 = onFulfilled return, or T if omitted/null/undefined.
            const tresult1: TypeId = if (args.len > 0)
                (self.callbackReturnInner(@enumFromInt(args[0])) orelse T)
            else
                T;
            // TResult2 = onRejected return, or never if omitted.
            const tresult2: TypeId = if (args.len > 1)
                (self.callbackReturnInner(@enumFromInt(args[1])) orelse tymod.ID_NEVER)
            else
                tymod.ID_NEVER;

            const combined: TypeId = if (tresult2.eq(tymod.ID_NEVER))
                tresult1
            else if (tresult1.eq(tymod.ID_NEVER))
                tresult2
            else
                self.store.unionOf(&.{ tresult1, tresult2 }) catch tresult1;
            return self.store.typeRef("Promise", &.{combined}) catch null;
        }

        // .catch(onR?) — TResult = onRejected return, or never if omitted.
        const tresult: TypeId = if (args.len > 0)
            (self.callbackReturnInner(@enumFromInt(args[0])) orelse tymod.ID_NEVER)
        else
            tymod.ID_NEVER;

        const combined: TypeId = if (tresult.eq(tymod.ID_NEVER))
            T
        else if (T.eq(tymod.ID_NEVER))
            tresult
        else
            self.store.unionOf(&.{ T, tresult }) catch T;
        return self.store.typeRef("Promise", &.{combined}) catch null;
    }

    /// Returns the "inner" result type of a callback argument — i.e. the return
    /// type of the callback function with Promise<X> unwrapped to X.
    /// Returns null when the arg is null/undefined (treat as absent callback).
    fn callbackReturnInner(self: *Checker, node: NodeIndex) ?TypeId {
        const cb_ty = self.typeOf(node);
        if (cb_ty.eq(tymod.ID_NULL) or cb_ty.eq(tymod.ID_UNDEFINED)) return null;
        if (tymod.isAny(&self.store, cb_ty)) return tymod.ID_ANY;
        const t = self.store.get(cb_ty);
        if (t.kind != .function_t) return null;
        const sigs = self.store.signaturesOf(t.signatures);
        if (sigs.len == 0) return tymod.ID_UNKNOWN;
        const ret = sigs[0].return_type;
        // Unwrap Promise<X> → X (promise flattening).
        if (tymod.isPromiseRef(&self.store, ret)) {
            const pt = self.store.get(ret);
            const pt_args = self.store.idsOf(pt.list_data);
            return if (pt_args.len > 0) pt_args[0] else tymod.ID_UNKNOWN;
        }
        return ret;
    }

    /// Match argument types against parameter types looking for
    /// type-parameter references; substitute the inferred bindings
    /// into `return_ty`.  Returns `null` when the callee isn't a
    /// generic function declaration we can find, or when there were
    /// no inferences to make.
    /// Collect generic type-parameter bindings for a call: type-param names
    /// from the callee decl, explicit type args (`fn<number>(x)`), and the rest
    /// inferred from argument types (any-wins via `matchTypeParam`, with rest
    /// parameters spreading each trailing arg against the rest element).  Fills
    /// `names`/`bindings` (unbound entries stay `TypeId.none`).  Returns the
    /// type-param count, or 0 if the callee isn't a generic fn decl we resolve.
    fn collectCallBindings(
        self: *Checker,
        callee: NodeIndex,
        call: NodeIndex,
        names: *[8][]const u8,
        bindings: *[8]TypeId,
    ) usize {
        const fn_decl = self.findCalleeFnDecl(callee) orelse return 0;
        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(self.ast_ref.nodeData(fn_decl).lhs));
        if (fd.type_params_end <= fd.type_params) return 0;
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        var tp_count: usize = 0;
        if (fd.type_params_end <= ext_len) {
            for (self.ast_ref.extra_data[fd.type_params..fd.type_params_end]) |raw| {
                if (tp_count >= names.len) break;
                const tp_node: NodeIndex = @enumFromInt(raw);
                if (self.ast_ref.nodeTag(tp_node) != .ts_type_parameter) continue;
                names[tp_count] = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp_node));
                tp_count += 1;
            }
        }
        if (tp_count == 0) return 0;
        for (0..tp_count) |b| bindings[b] = TypeId.none;
        // Explicit type args (`fn<T>(x)` via ts_instantiation_expr).
        {
            var c = callee;
            while (self.ast_ref.nodeTag(c) == .grouping_expr) c = self.ast_ref.nodeData(c).lhs;
            if (self.ast_ref.nodeTag(c) == .ts_instantiation_expr) {
                const inst_d = self.ast_ref.nodeData(c);
                if (inst_d.rhs != .none) {
                    const sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(inst_d.rhs));
                    if (sr.end <= ext_len) {
                        for (self.ast_ref.extra_data[sr.start..sr.end], 0..) |raw, ti| {
                            if (ti >= tp_count) break;
                            bindings[ti] = self.resolveTypeNode(@enumFromInt(raw));
                        }
                    }
                }
            }
        }
        if (fd.params_end > ext_len) return tp_count;
        const params = self.ast_ref.extra_data[fd.params..fd.params_end];
        // Detect a trailing rest parameter (peel default/parameter-property).
        var rest_pi: usize = std.math.maxInt(usize);
        if (params.len > 0) {
            var pn: NodeIndex = @enumFromInt(params[params.len - 1]);
            if (self.ast_ref.nodeTag(pn) == .assignment_pattern) pn = self.ast_ref.nodeData(pn).lhs;
            if (self.ast_ref.nodeTag(pn) == .ts_parameter_property) pn = self.ast_ref.nodeData(pn).lhs;
            if (self.ast_ref.nodeTag(pn) == .rest_element) rest_pi = params.len - 1;
        }
        const arg_nodes = self.callArguments(call);
        for (arg_nodes, 0..) |arg_raw, ai| {
            const pidx = if (ai < params.len) ai else rest_pi;
            if (pidx == std.math.maxInt(usize) or pidx >= params.len) continue;
            const param: NodeIndex = @enumFromInt(params[pidx]);
            const param_ty_node = self.paramAnnotationNode(param) orelse continue;
            const arg_ty = self.typeOf(@enumFromInt(arg_raw));
            // For the rest param each trailing arg matches the rest ELEMENT.
            const match_node = if (pidx == rest_pi) self.restElementMatchNode(param_ty_node) else param_ty_node;
            self.matchTypeParam(match_node, arg_ty, names[0..tp_count], bindings[0..tp_count]);
        }
        return tp_count;
    }

    /// The node a rest parameter's trailing args should match against: the
    /// element of `T[]` / `Array<T>`, else the annotation itself (a bare type
    /// parameter `E`, matched directly — any-wins then widens it to `any`).
    fn restElementMatchNode(self: *Checker, ty_node: NodeIndex) NodeIndex {
        const tag = self.ast_ref.nodeTag(ty_node);
        if (tag == .ts_array_type) return self.ast_ref.nodeData(ty_node).lhs;
        if (tag == .ts_type_reference) {
            const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ty_node));
            if (std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "ReadonlyArray")) {
                const first = self.firstTypeArg(ty_node);
                if (first != .none) return first;
            }
        }
        return ty_node;
    }

    fn inferGenericReturn(self: *Checker, callee: NodeIndex, call: NodeIndex, return_ty: TypeId) ?TypeId {
        var names_buf: [8][]const u8 = undefined;
        var bindings_buf: [8]TypeId = undefined;
        const tp_count = self.collectCallBindings(callee, call, &names_buf, &bindings_buf);
        if (tp_count == 0) return null;
        var any_bound = false;
        for (bindings_buf[0..tp_count]) |b| {
            if (!b.eq(TypeId.none)) { any_bound = true; break; }
        }
        if (!any_bound) return null;
        for (bindings_buf[0..tp_count]) |*b| {
            if (b.eq(TypeId.none)) b.* = tymod.ID_UNKNOWN;
        }
        return self.substituteTypeId(return_ty, names_buf[0..tp_count], bindings_buf[0..tp_count]);
    }

    /// Instantiated type of parameter `param_index` for the generic call at
    /// `call` — infer the callee's type args from the arguments, then substitute
    /// them into that parameter's annotation.  Returns null when the callee
    /// isn't a generic fn decl, the param has no annotation, or nothing bound.
    /// Backs the type-aware facade's no-unsafe-argument (instantiated params).
    pub fn inferGenericParamType(self: *Checker, call: NodeIndex, param_index: u32) ?TypeId {
        const callee = self.ast_ref.nodeData(call).lhs;
        if (callee == .none) return null;
        const fn_decl = self.findCalleeFnDecl(callee) orelse return null;
        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(self.ast_ref.nodeData(fn_decl).lhs));
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        if (fd.params_end > ext_len) return null;
        const params = self.ast_ref.extra_data[fd.params..fd.params_end];
        if (param_index >= params.len) return null;
        const param: NodeIndex = @enumFromInt(params[param_index]);
        const param_ty_node = self.paramAnnotationNode(param) orelse return null;
        var names_buf: [8][]const u8 = undefined;
        var bindings_buf: [8]TypeId = undefined;
        const tp_count = self.collectCallBindings(callee, call, &names_buf, &bindings_buf);
        if (tp_count == 0) return null;
        for (bindings_buf[0..tp_count]) |*b| {
            if (b.eq(TypeId.none)) b.* = tymod.ID_UNKNOWN;
        }
        return self.resolveTypeNodeWithSubst(param_ty_node, names_buf[0..tp_count], bindings_buf[0..tp_count]);
    }

    fn callArguments(self: *Checker, call: NodeIndex) []const u32 {
        const d = self.ast_ref.nodeData(call);
        if (d.rhs == .none) return &.{};
        const sr = self.ast_ref.extraData(ast.SubRange, @intFromEnum(d.rhs));
        if (sr.start >= sr.end or sr.end > self.ast_ref.extra_data.len) return &.{};
        return self.ast_ref.extra_data[sr.start..sr.end];
    }

    fn paramAnnotationNode(self: *Checker, param: NodeIndex) ?NodeIndex {
        var p = param;
        if (self.ast_ref.nodeTag(p) == .assignment_pattern) p = self.ast_ref.nodeData(p).lhs;
        if (self.ast_ref.nodeTag(p) == .ts_parameter_property) p = self.ast_ref.nodeData(p).lhs;
        // A rest_element holds its annotation on `.rhs` (not on the inner
        // identifier) — `...p: E` → rd.rhs is the ts_type_annotation for E.
        if (self.ast_ref.nodeTag(p) == .rest_element) {
            const rd = self.ast_ref.nodeData(p);
            if (rd.rhs != .none and self.ast_ref.nodeTag(rd.rhs) == .ts_type_annotation)
                return self.ast_ref.nodeData(rd.rhs).lhs;
            return null;
        }
        if (self.ast_ref.nodeTag(p) != .identifier) return null;
        const bd = self.ast_ref.nodeData(p);
        if (bd.rhs == .none or self.ast_ref.nodeTag(bd.rhs) != .ts_type_annotation) return null;
        return self.ast_ref.nodeData(bd.rhs).lhs;
    }

    /// Walk `param_node` looking for `ts_type_reference`s whose name
    /// matches one of `names`.  When found and not yet bound, set
    /// `bindings[i]` to `arg_ty`.  Recurses through unions /
    /// intersections / arrays / `Foo<T>` type args.
    fn matchTypeParam(
        self: *Checker,
        param_node: NodeIndex,
        arg_ty: TypeId,
        names: []const []const u8,
        bindings: []TypeId,
    ) void {
        var n = param_node;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        const tag = self.ast_ref.nodeTag(n);
        if (tag == .ts_type_reference) {
            const tname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
            for (names, 0..) |k, i| {
                if (std.mem.eql(u8, k, tname)) {
                    // any-wins: if any inference candidate for this type
                    // parameter is `any`, the inferred type is `any` (TS
                    // semantics).  Otherwise first-write-wins.
                    if (tymod.isAny(&self.store, arg_ty)) {
                        bindings[i] = tymod.ID_ANY;
                    } else if (bindings[i].eq(TypeId.none)) {
                        bindings[i] = arg_ty;
                    }
                    return;
                }
            }
            // `Foo<T>` — check common patterns:
            // - `Array<T>` or `ReadonlyArray<T>` matched against an array type
            // - generic `Foo<T>` matched against a type_ref with same outer name
            if ((std.mem.eql(u8, tname, "Array") or std.mem.eql(u8, tname, "ReadonlyArray")) and
                (self.store.get(arg_ty).kind == .array_t or
                 self.store.get(arg_ty).kind == .readonly_array_t or
                 self.store.get(arg_ty).kind == .tuple_t))
            {
                const elems = self.store.idsOf(self.store.get(arg_ty).list_data);
                const first_ta = self.firstTypeArg(n);
                if (first_ta != .none and elems.len > 0) {
                    self.matchTypeParam(first_ta, elems[0], names, bindings);
                }
                return;
            }
            const data = self.ast_ref.nodeData(n);
            if (data.rhs != .none) {
                const sr = self.safeSubRange(data.rhs) orelse return;
                const type_arg_nodes = self.ast_ref.extra_data[sr.start..sr.end];
                const arg_t = self.store.get(arg_ty);
                if (arg_t.kind == .type_ref and std.mem.eql(u8, arg_t.name, tname)) {
                    const arg_type_args = self.store.idsOf(arg_t.list_data);
                    for (type_arg_nodes, 0..) |raw, ai| {
                        if (ai >= arg_type_args.len) break;
                        const ta_node: NodeIndex = @enumFromInt(raw);
                        self.matchTypeParam(ta_node, arg_type_args[ai], names, bindings);
                    }
                }
            }
            return;
        }
        if (tag == .ts_array_type) {
            // `T[]` matched against `arg_ty[]` — bind T to the element
            // type of arg_ty when arg_ty is an array.
            const at = self.store.get(arg_ty);
            if (at.kind == .array_t or at.kind == .readonly_array_t or at.kind == .tuple_t) {
                const elems = self.store.idsOf(at.list_data);
                if (elems.len > 0) {
                    const inner = self.ast_ref.nodeData(n).lhs;
                    self.matchTypeParam(inner, elems[0], names, bindings);
                }
            }
            return;
        }
        // `readonly T[]` — ts_keyof_type with "readonly" main_token wrapping a ts_array_type.
        // Strip the readonly and recurse into the inner array type.
        if (tag == .ts_keyof_type) {
            const main_tok = self.ast_ref.nodeMainToken(n);
            if (std.mem.eql(u8, self.ast_ref.tokenText(main_tok), "readonly")) {
                const inner = self.ast_ref.nodeData(n).lhs;
                if (inner != .none) self.matchTypeParam(inner, arg_ty, names, bindings);
            }
            return;
        }
        if (tag == .ts_union_type or tag == .ts_intersection_type) {
            const d = self.ast_ref.nodeData(n);
            const s = @intFromEnum(d.lhs);
            const e = @intFromEnum(d.rhs);
            if (e > s and e <= self.ast_ref.extra_data.len) {
                for (self.ast_ref.extra_data[s..e]) |raw| {
                    const m: NodeIndex = @enumFromInt(raw);
                    self.matchTypeParam(m, arg_ty, names, bindings);
                }
            }
            return;
        }
        // `(p: T) => U` matched against a function_t arg — bind param types and return type.
        if (tag == .ts_function_type or tag == .ts_constructor_type) {
            const at = self.store.get(arg_ty);
            if (at.kind != .function_t) return;
            const sig_ids = self.store.idsOf(at.list_data);
            if (sig_ids.len == 0) return;
            const ret_id = sig_ids[sig_ids.len - 1];
            const fn_data = self.ast_ref.nodeData(n);
            if (fn_data.lhs == .none) return;
            const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(fn_data.lhs));
            // Match parameter type annotations against param types in the arg function_t.
            const param_type_ids = sig_ids[0..sig_ids.len - 1];
            if (fd.params_end > fd.params and fd.params_end <= self.ast_ref.extra_data.len) {
                const params = self.ast_ref.extra_data[fd.params..fd.params_end];
                for (params, 0..) |raw, pi| {
                    if (pi >= param_type_ids.len) break;
                    const param: NodeIndex = @enumFromInt(raw);
                    const pty_node = self.paramAnnotationNode(param) orelse continue;
                    self.matchTypeParam(pty_node, param_type_ids[pi], names, bindings);
                }
            }
            // Match return type annotation against the arg's return type.
            if (fd.return_type != .none) {
                self.matchTypeParam(fd.return_type, ret_id, names, bindings);
            }
        }
    }

    /// For a call's callee, find the matching function declaration
    /// node in the AST (by identifier name).  Returns null if the
    /// callee isn't a simple identifier or we can't find a fn-decl.
    fn findCalleeFnDecl(self: *Checker, callee: NodeIndex) ?NodeIndex {
        var c = callee;
        while (self.ast_ref.nodeTag(c) == .grouping_expr or
               self.ast_ref.nodeTag(c) == .ts_instantiation_expr)
            c = self.ast_ref.nodeData(c).lhs;
        if (self.ast_ref.nodeTag(c) != .identifier) return null;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(c));
        if (name.len == 0) return null;
        const list = self.value_decl_by_name.get(name) orelse return null;
        for (list.items) |ni| {
            const t = self.ast_ref.nodeTag(ni);
            if (t == .fn_decl or t == .async_fn_decl or t == .ts_declare_function or
                t == .generator_fn_decl or t == .async_generator_fn_decl)
            {
                const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(self.ast_ref.nodeData(ni).lhs));
                if (fd.name == .none) continue;
                const dn = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(fd.name));
                if (std.mem.eql(u8, dn, name)) return ni;
                continue;
            }
            // const/let declarator: `const name: <T>(...) => ...`
            // Return the ts_function_type node — it has the same FnData layout
            // so inferGenericReturn can extract type params and params from it.
            if (t == .declarator) {
                const dd = self.ast_ref.nodeData(ni);
                if (dd.lhs == .none or self.ast_ref.nodeTag(dd.lhs) != .identifier) continue;
                const dn = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(dd.lhs));
                if (!std.mem.eql(u8, dn, name)) continue;
                const id_d = self.ast_ref.nodeData(dd.lhs);
                if (id_d.rhs == .none or self.ast_ref.nodeTag(id_d.rhs) != .ts_type_annotation) continue;
                const ann_inner = self.ast_ref.nodeData(id_d.rhs).lhs;
                if (ann_inner == .none or self.ast_ref.nodeTag(ann_inner) != .ts_function_type) continue;
                // Only return if the function type is generic (has type params) —
                // otherwise there is nothing to substitute.
                const fn_d = self.ast_ref.nodeData(ann_inner);
                const fn_fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(fn_d.lhs));
                if (fn_fd.type_params_end <= fn_fd.type_params) continue;
                return ann_inner;
            }
        }
        return null;
    }

    /// True when `node` is part of an optional chain — i.e. walking down
    /// the left-spine of member/call expressions reaches an
    /// `optional_*` node.  Matches TS's "once you `?.`, the whole chain
    /// propagates undefined" rule.
    fn calleeIsInOptionalChain(self: *Checker, node: NodeIndex) bool {
        var cur = node;
        while (cur != .none) {
            const tag = self.ast_ref.nodeTag(cur);
            switch (tag) {
                .optional_member_expr,
                .optional_computed_member_expr,
                .optional_call_expr => return true,
                .member_expr, .computed_member_expr, .call_expr => {
                    cur = self.ast_ref.nodeData(cur).lhs;
                },
                .grouping_expr => {
                    cur = self.ast_ref.nodeData(cur).lhs;
                },
                else => return false,
            }
        }
        return false;
    }

    /// For `new X<T>()` / `new X()`: peel ts_instantiation_expr / new_expr
    /// / grouping wrappers to get the underlying class identifier and
    /// its type args, then resolve to the corresponding type-ref or
    /// declared object_t.
    fn newExprInstanceType(self: *Checker, callee: NodeIndex) ?TypeId {
        var c = callee;
        // Peel grouping_expr and new_expr (when the parser shape is
        // `call_expr(new_expr(...))` for `new X<T>()` calls).
        while (true) {
            const tag = self.ast_ref.nodeTag(c);
            if (tag == .grouping_expr) { c = self.ast_ref.nodeData(c).lhs; continue; }
            if (tag == .new_expr) { c = self.ast_ref.nodeData(c).lhs; continue; }
            break;
        }
        var type_args_start: u32 = 0;
        var type_args_end: u32 = 0;
        if (self.ast_ref.nodeTag(c) == .ts_instantiation_expr) {
            const idata = self.ast_ref.nodeData(c);
            if (idata.rhs != .none) {
                if (self.safeSubRange(idata.rhs)) |range| {
                    type_args_start = range.start;
                    type_args_end = range.end;
                }
            }
            c = idata.lhs;
        }
        // Peel any leftover new_expr / grouping wrappers below the
        // ts_instantiation_expr layer.
        while (true) {
            const tag = self.ast_ref.nodeTag(c);
            if (tag == .grouping_expr or tag == .new_expr) {
                c = self.ast_ref.nodeData(c).lhs;
                continue;
            }
            break;
        }
        if (self.ast_ref.nodeTag(c) != .identifier) return null;
        var args_buf: [4]TypeId = undefined;
        const args_count = blk: {
            if (type_args_end <= type_args_start) break :blk 0;
            const slice = self.ast_ref.extra_data[type_args_start..type_args_end];
            const n = @min(slice.len, args_buf.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const arg_node: NodeIndex = @enumFromInt(slice[i]);
                args_buf[i] = self.resolveTypeNode(arg_node);
            }
            break :blk n;
        };
        return self.classOrLibInstance(c, args_buf[0..args_count]);
    }

    /// True when the callee looks constructible — a ts_instantiation_expr
    /// over a class/lib identifier OR a new_expr child (which suggests
    /// the parser wrapped `new X<T>()` as `call_expr(new_expr(...))`).
    fn calleeIsConstructible(self: *Checker, callee: NodeIndex) bool {
        var c = callee;
        while (self.ast_ref.nodeTag(c) == .grouping_expr) c = self.ast_ref.nodeData(c).lhs;
        return switch (self.ast_ref.nodeTag(c)) {
            .ts_instantiation_expr, .new_expr => true,
            else => false,
        };
    }

    fn classOrLibInstance(self: *Checker, callee_ident: NodeIndex, args: []const TypeId) ?TypeId {
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(callee_ident));
        // Built-in lib types — produce a type_ref carrying the args.
        if (std.mem.eql(u8, name, "Set") or std.mem.eql(u8, name, "Map") or
            std.mem.eql(u8, name, "Promise") or std.mem.eql(u8, name, "WeakSet") or
            std.mem.eql(u8, name, "WeakMap") or std.mem.eql(u8, name, "Date") or
            std.mem.eql(u8, name, "RegExp") or std.mem.eql(u8, name, "Array") or
            std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Number") or
            std.mem.eql(u8, name, "Boolean") or std.mem.eql(u8, name, "Object") or
            std.mem.eql(u8, name, "Symbol") or
            // Error family + URL — globals not declared in-file; produce a named
            // type_ref so the facade's name/lib-specifier matching works
            // (restrict-template-expressions' default `allow` includes Error/URL).
            std.mem.eql(u8, name, "Error") or std.mem.eql(u8, name, "TypeError") or
            std.mem.eql(u8, name, "RangeError") or std.mem.eql(u8, name, "SyntaxError") or
            std.mem.eql(u8, name, "ReferenceError") or std.mem.eql(u8, name, "EvalError") or
            std.mem.eql(u8, name, "URIError") or std.mem.eql(u8, name, "AggregateError") or
            std.mem.eql(u8, name, "URL") or std.mem.eql(u8, name, "URLSearchParams"))
        {
            return self.store.typeRef(name, args) catch null;
        }
        // User-declared class or interface — return typeRef so the instance
        // type renders as the class name (matching tsc) rather than expanding
        // to the structural object shape.  Member access resolves lazily via
        // memberOnApparentType → resolveDeclaredType.
        if (self.type_decl_nodes.get(name)) |decl| {
            const dtag = self.ast_ref.nodeTag(decl);
            if (dtag == .class_decl or dtag == .ts_interface_decl) {
                return self.store.typeRef(name, args) catch null;
            }
        }
        // Type alias or enum (structural resolve).
        if (self.resolveDeclaredType(name)) |ty| return ty;
        return null;
    }

    fn inferArith(self: *Checker, node: NodeIndex, tag: ast.Node.Tag) TypeId {
        // Only `+` can return string.  Others coerce to number/bigint;
        // we approximate as number unless either operand is bigint.
        const data = self.ast_ref.nodeData(node);
        // If either operand is missing (unresolvable), return any
        if (data.lhs == .none or data.rhs == .none) return tymod.ID_ANY;
        const a = self.typeOf(data.lhs);
        const b = self.typeOf(data.rhs);
        if (tag == .add) {
            // string + anything → string.  Match both `string` and
            // `string_literal` operands.
            if (isStringish(&self.store, a) or isStringish(&self.store, b)) return tymod.ID_STRING;
            // Either side any → any (so unsafe-* fires through arithmetic).
            if (tymod.isAny(&self.store, a) or tymod.isAny(&self.store, b)) return tymod.ID_ANY;
            if (isBigintish(&self.store, a) or isBigintish(&self.store, b)) return tymod.ID_BIGINT;
            // For `+`, both operands must be numeric (number or number_literal).
            // Non-numeric operands (boolean, Object, type parameter, null, undefined,
            // void, etc.) make the operation invalid → TypeScript returns `any`.
            if (isNumericish(&self.store, a) and isNumericish(&self.store, b)) return tymod.ID_NUMBER;
            return tymod.ID_ANY;
        }
        // `*`, `/`, `%`, `-`, `**` always coerce to number at runtime.
        // TypeScript types these as `number` even when operands are `any`,
        // so we do NOT short-circuit to `any` here.
        if (isBigintish(&self.store, a) or isBigintish(&self.store, b)) return tymod.ID_BIGINT;
        return tymod.ID_NUMBER;
    }

    fn isNumericish(store: *const tymod.TypeStore, id: TypeId) bool {
        const t = store.get(id);
        return t.kind == .number or t.kind == .number_literal;
    }

    fn isStringish(store: *const tymod.TypeStore, id: TypeId) bool {
        const t = store.get(id);
        if (t.kind == .string or t.kind == .string_literal) return true;
        if (t.kind == .union_t) {
            for (store.idsOf(t.list_data)) |m| {
                if (!isStringish(store, m)) return false;
            }
            return true;
        }
        return false;
    }

    fn isBigintish(store: *const tymod.TypeStore, id: TypeId) bool {
        const t = store.get(id);
        return t.kind == .bigint or t.kind == .bigint_literal;
    }

    /// Safely read a SubRange stored in a NodeIndex slot.  The parser
    /// uses .none for "no payload"; out-of-bounds extra indices appear
    /// when the parser stores 0 (root sentinel) for empty payloads.
    /// Returns null when the range can't be safely read or yields a
    /// span that extends past extra_data.
    fn safeSubRange(self: *Checker, slot: NodeIndex) ?SubRange {
        if (slot == .none) return null;
        const idx = @intFromEnum(slot);
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        if (idx + 1 >= ext_len) return null;
        const r = self.ast_ref.extraData(SubRange, idx);
        if (r.start > r.end or r.end > ext_len) return null;
        return r;
    }

    /// Several AST node tags (ts_union_type, ts_intersection_type,
    /// ts_tuple_type, ts_type_literal, template_literal) store the
    /// range start/end DIRECTLY in data.lhs/data.rhs as NodeIndex
    /// values — NOT a SubRange struct at an extra index.  This helper
    /// reads that pattern consistently.  Returns null when either slot
    /// is .none or the range extends past extra_data.
    fn directRange(self: *Checker, lhs: NodeIndex, rhs: NodeIndex) ?[]const u32 {
        if (lhs == .none or rhs == .none) return null;
        const s = @intFromEnum(lhs);
        const e = @intFromEnum(rhs);
        const ext_len: u32 = @intCast(self.ast_ref.extra_data.len);
        if (s > e or e > ext_len) return null;
        return self.ast_ref.extra_data[s..e];
    }

    /// Element type for an empty array literal `[]`.  TS gives an empty array
    /// BOUND to a variable (`const x = []`) the evolving-array element `any`,
    /// but a bare `[]` expression (return/argument/template) stays `never`.
    /// Returns true when `node` (an array literal) is the RHS initializer of a
    /// variable declarator whose LHS is an array-destructuring pattern.
    /// In this context TypeScript infers a fixed-length tuple rather than T[].
    fn isArrayInDestructuringRhs(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        if (node.toInt() >= parents.len) return false;
        const p = parents[node.toInt()];
        if (p == @intFromEnum(NodeIndex.none)) return false;
        const pn: NodeIndex = @enumFromInt(p);
        if (self.ast_ref.nodeTag(pn) != .declarator) return false;
        const pn_data = self.ast_ref.nodeData(pn);
        if (pn_data.rhs != node) return false;
        if (pn_data.lhs == .none) return false;
        return self.ast_ref.nodeTag(pn_data.lhs) == .array_pattern;
    }

    /// Returns true when `node` (an array literal) is the direct operand of a
    /// spread_element that is itself a call argument (`f(...[1, 2])`).
    /// TypeScript types spread array literals as tuples in this position only.
    fn isArrayInSpreadArg(self: *Checker, node: NodeIndex) bool {
        const parents = self.semantic.parent_indices;
        if (node.toInt() >= parents.len) return false;
        const p = parents[node.toInt()];
        if (p == @intFromEnum(NodeIndex.none)) return false;
        const pn: NodeIndex = @enumFromInt(p);
        if (self.ast_ref.nodeTag(pn) != .spread_element) return false;
        // Verify the spread_element itself is inside a call (not an array literal).
        if (pn.toInt() >= parents.len) return false;
        const gp_raw = parents[pn.toInt()];
        if (gp_raw == @intFromEnum(NodeIndex.none)) return false;
        const gp: NodeIndex = @enumFromInt(gp_raw);
        return switch (self.ast_ref.nodeTag(gp)) {
            .call_expr, .optional_call_expr,
            .new_expr, .tagged_template => true,
            else => false,
        };
    }

    /// This matches both rules at once: `const arg = []` passes restrict-template-
    /// expressions' allowArray (any element), while `return []` stays safe for
    /// no-unsafe-return (never[] is not an any-array).
    fn emptyArrayElem(self: *Checker, node: NodeIndex) TypeId {
        const parents = self.semantic.parent_indices;
        if (node.toInt() >= parents.len) return tymod.ID_NEVER;
        const p = parents[node.toInt()];
        if (p == @intFromEnum(NodeIndex.none)) return tymod.ID_NEVER;
        const pn: NodeIndex = @enumFromInt(p);
        const pn_tag = self.ast_ref.nodeTag(pn);
        // The array is the initializer of a `const`/`let`/`var` declarator or a
        // class property (`private x = []`) — both use evolving-array `any[]`.
        if (pn_tag == .declarator and self.ast_ref.nodeData(pn).rhs == node) {
            return tymod.ID_ANY;
        }
        if (pn_tag == .property_def or pn_tag == .computed_property_def) {
            return tymod.ID_ANY;
        }
        // In files compiled with `@strict: false`, TypeScript uses legacy widening
        // where an empty array not bound to a variable gets element type `undefined`
        // rather than `never`.
        if (self.checker_opts.strict_explicitly_false) return tymod.ID_UNDEFINED;
        return tymod.ID_NEVER;
    }

    fn inferArrayLiteral(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        const slice = self.directRange(data.lhs, data.rhs) orelse {
            const elem = self.emptyArrayElem(node);
            if (tymod.isAny(&self.store, elem)) return tymod.ID_ANY;
            return self.store.arrayOf(elem) catch tymod.ID_ANY;
        };
        if (slice.len == 0) {
            const elem = self.emptyArrayElem(node);
            if (tymod.isAny(&self.store, elem)) return tymod.ID_ANY;
            return self.store.arrayOf(elem) catch tymod.ID_ANY;
        }
        // Element type = union of element types.
        // For type inference, TypeScript excludes hole elements (elisions) — e.g.
        // `[,, 2, 3, 4]` infers as `number[]`, not a tuple with undefined holes.
        var buf: [32]TypeId = undefined;
        var n_used: usize = 0;
        const n = @min(slice.len, buf.len);
        var has_spread = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const elem_node: NodeIndex = @enumFromInt(slice[i]);
            if (elem_node == .none) {
                // Hole/elision: skip for type inference (TypeScript ignores holes).
                continue;
            }
            const elem_tag = self.ast_ref.nodeTag(elem_node);
            if (elem_tag == .spread_element) {
                has_spread = true;
                // Best-effort: if spread source is array, peel; else any.
                const inner = self.typeOf(self.ast_ref.nodeData(elem_node).lhs);
                const t = self.store.get(inner);
                if (t.kind == .array_t or t.kind == .readonly_array_t) {
                    const elems = self.store.idsOf(t.list_data);
                    buf[n_used] = if (elems.len == 0) tymod.ID_ANY else elems[0];
                } else {
                    buf[n_used] = tymod.ID_ANY;
                }
            } else {
                buf[n_used] = self.typeOf(elem_node);
            }
            n_used += 1;
        }
        // If ALL elements were holes, treat as empty array.
        if (n_used == 0) {
            const elem = self.emptyArrayElem(node);
            if (tymod.isAny(&self.store, elem)) return tymod.ID_ANY;
            return self.store.arrayOf(elem) catch tymod.ID_ANY;
        }
        // For homogeneous primitive-literal arrays (all string, all number, all boolean,
        // all bigint), tsc returns T[] not a tuple. Widen and return T[].
        // For heterogeneous or non-literal arrays, keep the tuple so destructuring
        // can use per-element types.
        var all_same_kind = true;
        const first_kind = self.store.get(buf[0]).kind;
        const is_primitive_literal = switch (first_kind) {
            .string_literal, .number_literal, .bigint_literal, .boolean_literal => true,
            else => false,
        };
        if (is_primitive_literal) {
            for (1..n_used) |j| {
                if (self.store.get(buf[j]).kind != first_kind) {
                    all_same_kind = false;
                    break;
                }
            }
        } else {
            all_same_kind = false;
        }
        if (all_same_kind) {
            // All elements same primitive literal kind → T[] in most contexts.
            // Exception: when the array literal is the RHS of an array-destructuring
            // declarator, tsc infers a fixed-length tuple ([1, 2] → [number, number]).
            // Special case: enum members widen to their enum type, not the underlying number.
            const elem_t: TypeId = blk: {
                if (first_kind == .number_literal) {
                    const first_enum_name = self.store.get(buf[0]).enum_name;
                    if (first_enum_name.len > 0) {
                        var all_same_enum = true;
                        for (1..n_used) |j| {
                            if (!std.mem.eql(u8, self.store.get(buf[j]).enum_name, first_enum_name)) {
                                all_same_enum = false;
                                break;
                            }
                        }
                        if (all_same_enum) {
                            break :blk self.store.typeRef(first_enum_name, &.{}) catch tymod.ID_NUMBER;
                        }
                    }
                }
                break :blk switch (first_kind) {
                    .string_literal => tymod.ID_STRING,
                    .number_literal => tymod.ID_NUMBER,
                    .bigint_literal => tymod.ID_BIGINT,
                    .boolean_literal => tymod.ID_BOOLEAN,
                    else => unreachable,
                };
            };
            if (self.isArrayInDestructuringRhs(node) or self.isArrayInSpreadArg(node)) {
                var tup_buf: [32]TypeId = undefined;
                for (0..n_used) |j| tup_buf[j] = elem_t;
                const list = self.store.appendTypeIds(tup_buf[0..n_used]) catch
                    return self.store.arrayOf(elem_t) catch tymod.ID_ANY;
                return self.store.add(.{ .kind = .tuple_t, .list_data = list }) catch tymod.ID_ANY;
            }
            return self.store.arrayOf(elem_t) catch tymod.ID_ANY;
        }
        // Widen any literal elements to their base types, then check for
        // homogeneity. TypeScript widens `[1, "a", true]` to `[number, string, boolean]`
        // and widens `[f, f, f]` (identical elements) to `T[]`.
        var widened_elems_buf: [32]TypeId = undefined;
        var any_widened = false;
        for (0..n_used) |j| {
            const et = self.store.get(buf[j]);
            const w: TypeId = switch (et.kind) {
                .string_literal => blk: { any_widened = true; break :blk tymod.ID_STRING; },
                .number_literal => blk: { any_widened = true; break :blk tymod.ID_NUMBER; },
                .bigint_literal => blk: { any_widened = true; break :blk tymod.ID_BIGINT; },
                .boolean_literal => blk: { any_widened = true; break :blk tymod.ID_BOOLEAN; },
                else => buf[j],
            };
            widened_elems_buf[j] = w;
        }
        // If all (post-widening) elements are the same type, return T[].
        // Covers [C, C, C] → (typeof C)[], [f, g] when f≡g → (() => T)[].
        if (!has_spread) {
            var all_same_id = true;
            for (1..n_used) |j| {
                if (!widened_elems_buf[j].eq(widened_elems_buf[0])) {
                    all_same_id = false;
                    break;
                }
            }
            if (all_same_id) {
                if (self.isArrayInDestructuringRhs(node) or self.isArrayInSpreadArg(node)) {
                    const list = self.store.appendTypeIds(widened_elems_buf[0..n_used]) catch
                        return self.store.arrayOf(widened_elems_buf[0]) catch tymod.ID_ANY;
                    return self.store.add(.{ .kind = .tuple_t, .list_data = list }) catch tymod.ID_ANY;
                }
                return self.store.arrayOf(widened_elems_buf[0]) catch tymod.ID_ANY;
            }
        }
        if (any_widened and !has_spread) {
            const list = self.store.appendTypeIds(widened_elems_buf[0..n_used]) catch
                return self.store.arrayOf(self.store.unionOf(widened_elems_buf[0..n_used]) catch tymod.ID_ANY) catch tymod.ID_ANY;
            return self.store.add(.{ .kind = .tuple_t, .list_data = list }) catch tymod.ID_ANY;
        }
        // No literals to widen: heterogeneous non-literal elements.
        // In destructuring (`const [a, b] = [d1, d2]`) keep per-position types as a tuple.
        // Otherwise TypeScript infers a union array: [d1, d2] → (Derived1 | Derived2)[].
        if (!has_spread) {
            if (self.isArrayInDestructuringRhs(node) or self.isArrayInSpreadArg(node)) {
                const list = self.store.appendTypeIds(buf[0..n_used]) catch
                    return self.store.arrayOf(self.store.unionOf(buf[0..n_used]) catch tymod.ID_ANY) catch tymod.ID_ANY;
                return self.store.add(.{ .kind = .tuple_t, .list_data = list }) catch tymod.ID_ANY;
            }
            sortUnionByTypePriority(&self.store, buf[0..n_used]);
            return self.store.arrayOf(self.store.unionOf(buf[0..n_used]) catch tymod.ID_ANY) catch tymod.ID_ANY;
        }
        var widened_buf: [32]TypeId = undefined;
        for (0..n_used) |j| {
            const elem_t = self.store.get(buf[j]);
            const widened = switch (elem_t.kind) {
                .string_literal => tymod.ID_STRING,
                .number_literal => tymod.ID_NUMBER,
                .bigint_literal => tymod.ID_BIGINT,
                .boolean_literal => tymod.ID_BOOLEAN,
                else => buf[j],
            };
            widened_buf[j] = widened;
        }
        // Sort union members by TypeScript's canonical TypeFlags priority so
        // inferred unions like (string | number)[] match tsc's output order.
        sortUnionByTypePriority(&self.store, widened_buf[0..n_used]);
        const elem_t = self.store.unionOf(widened_buf[0..n_used]) catch tymod.ID_ANY;
        return self.store.arrayOf(elem_t) catch tymod.ID_ANY;
    }

    fn methodFirstParamIsThisVoid(self: *Checker, params_start: u32, params_end: u32) bool {
        if (params_end <= params_start) return false;
        if (params_end > self.ast_ref.extra_data.len) return false;
        const first_raw = self.ast_ref.extra_data[params_start];
        const first: NodeIndex = @enumFromInt(first_raw);
        if (self.ast_ref.nodeTag(first) != .identifier) return false;
        const tok = self.ast_ref.nodeMainToken(first);
        if (!std.mem.eql(u8, self.ast_ref.tokenText(tok), "this")) return false;
        const ann = self.ast_ref.nodeData(first).rhs;
        if (ann == .none) return false;
        if (self.ast_ref.nodeTag(ann) != .ts_type_annotation) return false;
        const ty_node = self.ast_ref.nodeData(ann).lhs;
        if (self.ast_ref.nodeTag(ty_node) != .ts_type_reference) return false;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ty_node));
        return std.mem.eql(u8, name, "void");
    }

    fn fnFirstParamIsThisVoid(self: *Checker, fn_node: NodeIndex) bool {
        const data = self.ast_ref.nodeData(fn_node);
        if (data.lhs == .none) return false;
        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
        if (fd.params_end <= fd.params) return false;
        if (fd.params_end > self.ast_ref.extra_data.len) return false;
        const first_raw = self.ast_ref.extra_data[fd.params];
        const first: NodeIndex = @enumFromInt(first_raw);
        if (self.ast_ref.nodeTag(first) != .identifier) return false;
        const tok = self.ast_ref.nodeMainToken(first);
        if (!std.mem.eql(u8, self.ast_ref.tokenText(tok), "this")) return false;
        const ann = self.ast_ref.nodeData(first).rhs;
        if (ann == .none) return false;
        if (self.ast_ref.nodeTag(ann) != .ts_type_annotation) return false;
        const ty_node = self.ast_ref.nodeData(ann).lhs;
        if (self.ast_ref.nodeTag(ty_node) != .ts_type_reference) return false;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(ty_node));
        return std.mem.eql(u8, name, "void");
    }

    fn inferObjectLiteral(self: *Checker, node: NodeIndex) TypeId {
        // Walk the property list and build an object_t.  Spread/computed/
        // accessor properties bail out structurally — they widen the
        // type beyond what we can statically represent.
        const data = self.ast_ref.nodeData(node);
        const slice = self.directRange(data.lhs, data.rhs) orelse return tymod.ID_UNKNOWN;
        var buf: [16]tymod.ObjectProp = undefined;
        var n: usize = 0;
        for (slice) |raw| {
            if (n >= buf.len) break;
            const p: NodeIndex = @enumFromInt(raw);
            const pt = self.ast_ref.nodeTag(p);
            switch (pt) {
                .property => {
                    const pd = self.ast_ref.nodeData(p);
                    const key_name = self.staticPropertyKey(pd.lhs) orelse return tymod.ID_UNKNOWN;
                    const val_ty = self.typeOf(pd.rhs);
                    // Widen primitive literal types to their base types, but
                    // preserve the literal when an explicit type assertion pins
                    // it (e.g. `0 as 0`, `"x" as "x"`, `0 as const`).
                    const val_rhs_tag = self.ast_ref.nodeTag(pd.rhs);
                    const has_type_assertion = val_rhs_tag == .ts_as_expr or val_rhs_tag == .ts_type_assertion;
                    const val_t = self.store.get(val_ty);
                    const widened_ty = if (has_type_assertion) val_ty else switch (val_t.kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        else => val_ty,
                    };
                    const vt = self.ast_ref.nodeTag(pd.rhs);
                    const is_plain_fn = vt == .fn_expr or vt == .async_fn_expr or
                        vt == .generator_fn_expr or vt == .async_generator_fn_expr;
                    const this_void = is_plain_fn and self.fnFirstParamIsThisVoid(pd.rhs);
                    const is_fn = is_plain_fn and !this_void;
                    // Object-literal `prop: function() {}` is a
                    // PropertyAssignment in TS — `unbound-method` reports
                    // it with messageId "unboundWithoutThisAnnotation",
                    // NOT "unbound" (which is reserved for class fields).
                    // TypeScript displays `{ k: function(){} }` as property
                    // style `{ k: () => T }`, not method shorthand `{ k(): T }`.
                    _ = is_fn;
                    buf[n] = .{
                        .name = key_name,
                        .type_id = widened_ty,
                        .is_method = false,
                        .is_fn_property = false,
                    };
                    n += 1;
                },
                .shorthand_property => {
                    const pd = self.ast_ref.nodeData(p);
                    const key_name = self.staticPropertyKey(pd.lhs) orelse return tymod.ID_UNKNOWN;
                    const val_ty = self.typeOf(pd.lhs);
                    // Widen primitive literal types to their base types.
                    const val_t = self.store.get(val_ty);
                    const widened_ty = switch (val_t.kind) {
                        .string_literal => tymod.ID_STRING,
                        .number_literal => tymod.ID_NUMBER,
                        .boolean_literal => tymod.ID_BOOLEAN,
                        else => val_ty,
                    };
                    buf[n] = .{ .name = key_name, .type_id = widened_ty };
                    n += 1;
                },
                .method_def => {
                    // Object literal method shorthand `a() {}` — same
                    // shape as class methods: lhs = key, rhs = MethodData.
                    const pd = self.ast_ref.nodeData(p);
                    if (pd.lhs == .none or pd.rhs == .none) continue;
                    const key_name = self.staticPropertyKey(pd.lhs) orelse continue;
                    const md = self.ast_ref.extraData(ast.MethodData, @intFromEnum(pd.rhs));
                    const is_async = (md.modifiers & ast.ModifierBit.@"async") != 0;
                    const is_generator = (md.modifiers & ast.ModifierBit.generator) != 0;
                    const fn_ty = self.buildFunctionType(
                        md.params_start,
                        md.params_end,
                        md.return_type,
                        md.body,
                        is_async,
                        is_generator,
                    );
                    if (md.type_params < md.type_params_end)
                        self.registerFnTypeParams(fn_ty, md.type_params, md.type_params_end);
                    // `m(this: void, …)` is explicitly not a this-bound
                    // method — unbound-method should ignore it.
                    const this_void = self.methodFirstParamIsThisVoid(md.params_start, md.params_end);
                    buf[n] = .{
                        .name = key_name,
                        .type_id = fn_ty,
                        .is_method = !this_void,
                        .is_fn_property = false,
                    };
                    n += 1;
                },
                .spread_element => {
                    // Spreading any value (any/object/unknown/complex) makes the whole object `any`.
                    return tymod.ID_ANY;
                },
                // Bail on computed / accessors — structural type would not be sound.
                else => return tymod.ID_UNKNOWN,
            }
        }
        return self.store.objectOf(buf[0..n]) catch tymod.ID_UNKNOWN;
    }

    fn staticPropertyKey(self: *Checker, key: NodeIndex) ?[]const u8 {
        if (key == .none) return null;
        const tag = self.ast_ref.nodeTag(key);
        if (tag == .identifier or tag == .property_ident or tag == .property_literal) {
            const tok = self.ast_ref.nodeMainToken(key);
            return self.ast_ref.tokenText(tok);
        }
        if (tag == .string_literal) {
            const tok = self.ast_ref.nodeMainToken(key);
            const raw = self.ast_ref.tokenText(tok);
            if (raw.len >= 2) return raw[1 .. raw.len - 1];
        }
        return null;
    }

    fn inferMember(self: *Checker, node: NodeIndex) TypeId {
        const data = self.ast_ref.nodeData(node);
        // CommonJS: `module.exports` is the module's export object — tsc
        // displays `typeof module.exports`, but only when the module assigns
        // an object literal (`module.exports = {…}`); assigning an existing
        // entity (`module.exports = Foo`) shows that entity's type instead.
        if (self.checker_opts.is_js_file and self.isModuleExportsMember(node) and
            self.module_exports_literal)
        {
            return self.store.typeRef("typeof module.exports", &.{}) catch tymod.ID_ANY;
        }
        const obj_ty = self.typeOf(data.lhs);
        // Special case: enum member access (e.g. `SyntaxKind.Block`).
        // Enum values are typed as `any`, but we still want to look up
        // the member in the enum definition and return the literal type.
        if (tymod.isAny(&self.store, obj_ty)) {
            const obj_node = data.lhs;
            if (self.ast_ref.nodeTag(obj_node) == .identifier) {
                const obj_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(obj_node));
                // Check if this is an enum and try to look up the member
                if (self.enum_kinds.get(obj_name) != null) {
                    const tag = self.ast_ref.nodeTag(node);
                    const prop_name: []const u8 = switch (tag) {
                        .member_expr, .optional_member_expr => blk: {
                            if (data.rhs == .none) break :blk &.{};
                            const t = self.ast_ref.nodeMainToken(data.rhs);
                            break :blk self.ast_ref.tokenText(t);
                        },
                        else => return tymod.ID_ANY,
                    };
                    if (prop_name.len > 0) {
                        if (self.buildEnumObjectType(obj_name)) |obj_type| {
                            const ot = self.store.get(obj_type);
                            if (ot.kind == .object_t) {
                                for (self.store.propsOf(ot.object_props)) |p| {
                                    if (std.mem.eql(u8, p.name, prop_name)) {
                                        return p.type_id;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return tymod.ID_ANY;
        }
        const tag = self.ast_ref.nodeTag(node);
        const is_optional = tag == .optional_member_expr or tag == .optional_computed_member_expr;
        // Optional chain propagates: even on plain `.x` access, if a prior
        // step in the chain used `?.`, the receiver type carries `|
        // undefined` and we need to strip it before lookup.
        const in_chain = is_optional or self.calleeIsInOptionalChain(data.lhs);
        // Computed member: `obj[idx]`.  Handles array/tuple element access
        // and string-literal key indexing into object types.
        if (tag == .computed_member_expr or tag == .optional_computed_member_expr) {
            const lookup_obj = if (in_chain) self.stripNullishForLookup(obj_ty) else obj_ty;
            const inner = self.inferComputedMember(lookup_obj, data.rhs, data.lhs);
            return self.maybeAddOptionalUndefined(inner, obj_ty, in_chain);
        }
        const prop_name: []const u8 = switch (tag) {
            .member_expr, .optional_member_expr => blk: {
                if (data.rhs == .none) break :blk &.{};
                const t = self.ast_ref.nodeMainToken(data.rhs);
                break :blk self.ast_ref.tokenText(t);
            },
            else => return tymod.ID_UNKNOWN,
        };
        if (prop_name.len == 0) return tymod.ID_UNKNOWN;
        // For `obj?.prop` or any in-chain member access, strip the
        // nullish part for property lookup (`{a?:T} | undefined`'s `.a`
        // is `T | undefined`, not unknown).
        const lookup_ty = if (in_chain) self.stripNullishForLookup(obj_ty) else obj_ty;
        // Namespace-import member: `import * as NS from 'mod'; NS.Member`
        // When the receiver's type is unknown/error (i.e. not locally resolvable),
        // check if the object is a namespace-import identifier and look up the
        // member directly from the imported module's exports.
        if (lookup_ty.eq(tymod.ID_UNKNOWN) or lookup_ty.eq(tymod.ID_ERROR)) {
            const obj_node = data.lhs;
            const obj_tag = self.ast_ref.nodeTag(obj_node);
            if (obj_tag == .identifier) {
                const obj_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(obj_node));
                if (self.namespace_import_map.get(obj_name)) |mod_spec| {
                    if (self.inferMemberOnNamespace(mod_spec, prop_name)) |resolved| {
                        return self.maybeAddOptionalUndefined(resolved, obj_ty, in_chain);
                    }
                }
            }
        }
        // Expando function props: receiver typed `typeof foo` where foo has
        // `foo.x = v` assignments — resolve the prop to v's widened type.
        {
            const ot2 = self.store.get(lookup_ty);
            if (ot2.kind == .type_ref and std.mem.startsWith(u8, ot2.name, "typeof ")) {
                const root = ot2.name["typeof ".len..];
                if (self.expando_fns.get(root)) |list| {
                    for (list.items) |ep| {
                        if (!std.mem.eql(u8, ep.name, prop_name)) continue;
                        if (ep.value == .none) break;
                        const raw = self.typeOf(ep.value);
                        const widened = switch (self.store.get(raw).kind) {
                            .string_literal => tymod.ID_STRING,
                            .number_literal => tymod.ID_NUMBER,
                            .bigint_literal => tymod.ID_BIGINT,
                            .boolean_literal => tymod.ID_BOOLEAN,
                            else => raw,
                        };
                        return self.maybeAddOptionalUndefined(widened, obj_ty, in_chain);
                    }
                }
            }
        }
        const inner = self.memberOnApparentType(lookup_ty, prop_name, data.lhs);
        const result = self.maybeAddOptionalUndefined(inner, obj_ty, in_chain);
        return self.narrowMemberAtUse(node, result);
    }

    fn inferMemberOnNamespace(self: *Checker, module_spec: []const u8, member_name: []const u8) ?TypeId {
        if (self.module_resolver) |resolver| {
            if (self.file_path.len > 0) {
                const from_dir = std.fs.path.dirname(self.file_path) orelse ".";
                if (resolver.resolveExportedType(from_dir, module_spec, member_name, &self.store, self.gpa)) |t| return t;
            }
        }
        // Same-AST fallback: multi-file test sources are concatenated into one
        // AST (the oracle's combined sections), so the imported module's
        // exported declarations are resolvable by bare name — but ONLY when
        // the specifier names one of the concatenated sections; anything else
        // is genuinely external (stays any).  Skip when the member name is
        // itself an import binding (avoid resolving `b.b` to the alias `b`).
        if (self.moduleSpecIsLocalSection(module_spec) and
            self.namespace_import_map.get(member_name) == null)
        {
            if (self.typeOfNameByAstSearch(member_name)) |t| {
                if (!t.eq(tymod.ID_UNKNOWN) and !t.eq(tymod.ID_ANY)) return t;
            }
            if (self.resolveDeclaredType(member_name)) |t| {
                if (!t.eq(tymod.ID_UNKNOWN)) return t;
            }
        }
        return null;
    }

    /// True when an import specifier refers to one of the sibling sections
    /// concatenated into this AST (`./mod` matches section name `mod.ts`).
    fn moduleSpecIsLocalSection(self: *Checker, spec: []const u8) bool {
        if (self.checker_opts.available_modules.len == 0) return false;
        // node16/nodenext require explicit .js/.mjs/.cjs extensions on relative
        // imports — without one the module is unresolvable (tsc says any).
        if (self.checker_opts.isNode16Style() and node16UnresolvableSpec(spec)) return false;
        var base = spec;
        if (std.mem.lastIndexOfScalar(u8, base, '/')) |sl| base = base[sl + 1 ..];
        if (base.len == 0) return false;
        for (self.checker_opts.available_modules) |m| {
            var mn = m;
            if (std.mem.lastIndexOfScalar(u8, mn, '/')) |sl| mn = mn[sl + 1 ..];
            // Strip the extension (.ts/.tsx/.d.ts/.js/...) from the section name.
            if (std.mem.lastIndexOfScalar(u8, mn, '.')) |dot| mn = mn[0..dot];
            if (std.mem.endsWith(u8, mn, ".d")) mn = mn[0 .. mn.len - 2];
            if (std.mem.eql(u8, mn, base)) return true;
            // Specifier may itself carry an extension (`./mod.js`).
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |bdot| {
                if (std.mem.eql(u8, mn, base[0..bdot])) return true;
            }
        }
        return false;
    }

    fn stripNullishForLookup(self: *Checker, ty: TypeId) TypeId {
        const t = self.store.get(ty);
        if (t.kind != .union_t) return ty;
        var buf: [16]TypeId = undefined;
        var n: usize = 0;
        for (self.store.idsOf(t.list_data)) |m| {
            if (m.eq(tymod.ID_NULL) or m.eq(tymod.ID_UNDEFINED) or m.eq(tymod.ID_VOID)) continue;
            if (n >= buf.len) return ty;
            buf[n] = m;
            n += 1;
        }
        if (n == 0) return ty;
        if (n == 1) return buf[0];
        return self.store.unionOf(buf[0..n]) catch ty;
    }

    fn maybeAddOptionalUndefined(self: *Checker, inner: TypeId, obj_ty: TypeId, is_optional: bool) TypeId {
        if (!is_optional) return inner;
        // For `?.` access, if the object's type was nullish, the result
        // is `inner | undefined` (short-circuits to undefined).
        if (!self.typeContainsNullish(obj_ty)) return inner;
        if (self.typeContainsUndefined(inner)) return inner;
        return self.store.unionOf(&.{ inner, tymod.ID_UNDEFINED }) catch inner;
    }

    fn typeContainsNullish(self: *Checker, id: TypeId) bool {
        return self.typeContainsNull(id) or self.typeContainsUndefined(id);
    }

    fn typeContainsNull(self: *Checker, id: TypeId) bool {
        if (id.eq(tymod.ID_NULL)) return true;
        const t = self.store.get(id);
        if (t.kind == .null_t) return true;
        if (t.kind == .union_t) {
            for (self.store.idsOf(t.list_data)) |m| if (self.typeContainsNull(m)) return true;
        }
        return false;
    }

    fn typeContainsUndefined(self: *Checker, id: TypeId) bool {
        if (id.eq(tymod.ID_UNDEFINED) or id.eq(tymod.ID_VOID)) return true;
        const t = self.store.get(id);
        if (t.kind == .undefined_t or t.kind == .void_t) return true;
        if (t.kind == .union_t) {
            for (self.store.idsOf(t.list_data)) |m| if (self.typeContainsUndefined(m)) return true;
        }
        return false;
    }

    /// Compute the type of `obj[key]` access.  For arrays/tuples returns
    /// the element type; for objects with a static string key, returns
    /// that property's type; otherwise unknown.
    fn inferComputedMember(self: *Checker, obj_ty: TypeId, key_node: NodeIndex, obj_node: NodeIndex) TypeId {
        const input_was_unknown = obj_ty.eq(tymod.ID_UNKNOWN) or obj_ty.eq(tymod.ID_ERROR);
        if (key_node == .none) return if (input_was_unknown) tymod.ID_ANY else tymod.ID_UNKNOWN;
        const obj = self.store.get(obj_ty);
        // Array element access — index by number → element type.
        // For tuples, a numeric literal selects a specific element;
        // otherwise return the union of all elements.
        if (obj.kind == .array_t or obj.kind == .readonly_array_t) {
            // String-literal key on an array routes to the Array
            // prototype (`'length'`, `'push'`, ...) — not the element
            // type.
            if (self.ast_ref.nodeTag(key_node) == .string_literal) {
                const tok = self.ast_ref.nodeMainToken(key_node);
                const raw = self.ast_ref.tokenText(tok);
                if (raw.len >= 2) {
                    const key_name = raw[1 .. raw.len - 1];
                    if (std.mem.eql(u8, key_name, "length")) return tymod.ID_NUMBER;
                }
            }
            const elems = self.store.idsOf(obj.list_data);
            if (elems.len == 0) return tymod.ID_UNKNOWN;
            const elem_ty = elems[0];
            // Non-numeric index (symbol, variable, etc.) on an array: widen
            // element literals to their base types, since array[nonNumericKey]
            // can't access a specific numeric index.
            if (self.ast_ref.nodeTag(key_node) != .number_literal) {
                const et = self.store.get(elem_ty);
                // Handle unions of literals by widening each member.
                if (et.kind == .union_t) {
                    var buf: [32]TypeId = undefined;
                    var n: usize = 0;
                    for (self.store.idsOf(et.list_data)) |member| {
                        if (n >= buf.len) break;
                        const mt = self.store.get(member);
                        const widened = switch (mt.kind) {
                            .string_literal => tymod.ID_STRING,
                            .number_literal => tymod.ID_NUMBER,
                            .boolean_literal => tymod.ID_BOOLEAN,
                            .bigint_literal => tymod.ID_BIGINT,
                            else => member,
                        };
                        buf[n] = widened;
                        n += 1;
                    }
                    if (n == 0) return elem_ty;
                    if (n == 1) return buf[0];
                    return self.store.unionOf(buf[0..n]) catch elem_ty;
                }
                // Single literal type: widen directly.
                const widened = switch (et.kind) {
                    .string_literal => tymod.ID_STRING,
                    .number_literal => tymod.ID_NUMBER,
                    .boolean_literal => tymod.ID_BOOLEAN,
                    .bigint_literal => tymod.ID_BIGINT,
                    else => elem_ty,
                };
                return widened;
            }
            return elem_ty;
        }
        if (obj.kind == .tuple_t) {
            const elems = self.store.idsOf(obj.list_data);
            if (elems.len == 0) return tymod.ID_UNKNOWN;
            // Numeric literal index → specific element if in range.
            if (self.ast_ref.nodeTag(key_node) == .number_literal) {
                const tok = self.ast_ref.nodeMainToken(key_node);
                const text = self.ast_ref.tokenText(tok);
                const idx = std.fmt.parseInt(usize, text, 10) catch return tymod.ID_UNKNOWN;
                if (idx < elems.len) return self.peelRestElem(elems[idx]);
                return tymod.ID_UNDEFINED;
            }
            // Non-numeric index (symbol, variable, etc.) → union of all
            // element types, widened from literals to their base types.
            var buf: [32]TypeId = undefined;
            var n: usize = 0;
            for (elems) |elem| {
                if (n >= buf.len) break;
                const peeled = self.peelRestElem(elem);
                const et = self.store.get(peeled);
                const widened = switch (et.kind) {
                    .string_literal => tymod.ID_STRING,
                    .number_literal => tymod.ID_NUMBER,
                    .boolean_literal => tymod.ID_BOOLEAN,
                    .bigint_literal => tymod.ID_BIGINT,
                    else => peeled,
                };
                buf[n] = widened;
                n += 1;
            }
            if (n == 0) return tymod.ID_UNKNOWN;
            if (n == 1) return buf[0];
            return self.store.unionOf(buf[0..n]) catch elems[0];
        }
        // String literal key into object — look up by name.
        if (obj.kind == .object_t and self.ast_ref.nodeTag(key_node) == .string_literal) {
            const tok = self.ast_ref.nodeMainToken(key_node);
            const raw = self.ast_ref.tokenText(tok);
            if (raw.len >= 2) {
                const name = raw[1 .. raw.len - 1];
                for (self.store.propsOf(obj.object_props)) |p| {
                    if (std.mem.eql(u8, p.name, name)) return p.type_id;
                }
            }
        }
        // Computed key whose *type* is a string-literal (e.g.
        // `const k = 'fn'; obj[k]`).  Resolve the key node's value type and,
        // when it's a single string-literal, look the property up by name.
        if (obj.kind == .object_t and self.ast_ref.nodeTag(key_node) != .string_literal) {
            // Snapshot object_props BEFORE typeOf — that call may grow types.items,
            // making the `obj` pointer stale.
            const snap_props = obj.object_props;
            const key_ty = self.typeOf(key_node);
            const kt = self.store.get(key_ty);
            if (kt.kind == .string_literal) {
                const name: []const u8 = switch (kt.literal_value) {
                    .string => |s| s,
                    else => "",
                };
                if (name.len > 0) {
                    for (self.store.propsOf(snap_props)) |p| {
                        if (std.mem.eql(u8, p.name, name)) return p.type_id;
                    }
                }
            }
        }
        // Re-read obj after potential type additions from typeOf above.
        const obj2 = self.store.get(obj_ty);
        // Index signature `{[k: T]: V}` — match ANY key against the "[]"
        // sentinel prop stashed by `resolveTypeLiteral`.
        if (obj2.kind == .object_t) {
            for (self.store.propsOf(obj2.object_props)) |p| {
                if (std.mem.eql(u8, p.name, "[]")) return p.type_id;
            }
        }
        // Type reference (Promise / Array / etc.): resolve to the
        // underlying structural shape, then retry.
        if (obj2.kind == .type_ref) {
            const ref_name2 = obj2.name;  // snapshot before resolveDeclaredType may grow store
            if (self.resolveDeclaredType(ref_name2)) |resolved| {
                if (!resolved.eq(obj_ty)) {
                    return self.inferComputedMember(resolved, key_node, obj_node);
                }
            }
            // `ArrayLike<T>` / `Array<T>` / `ReadonlyArray<T>`: numeric
            // index returns the type argument.
            if (std.mem.eql(u8, ref_name2, "ArrayLike") or
                std.mem.eql(u8, ref_name2, "Array") or
                std.mem.eql(u8, ref_name2, "ReadonlyArray"))
            {
                const args = self.store.idsOf(obj2.list_data);
                if (args.len > 0) return args[0];
            }
            // Record<K, V>: any key access returns V (the value type, arg[1]).
            if (std.mem.eql(u8, ref_name2, "Record")) {
                const args = self.store.idsOf(obj2.list_data);
                if (args.len > 1) return args[1];
            }
            // Unresolved/unmodeled type_ref: computed access yields any.
            return tymod.ID_ANY;
        }
        // Union/intersection: walk members, take first concrete result.
        if (obj.kind == .union_t or obj.kind == .intersection_t) {
            for (self.store.idsOf(obj.list_data)) |m| {
                const t = self.inferComputedMember(m, key_node, obj_node);
                if (!tymod.isUnknown(&self.store, t)) return t;
            }
        }
        return if (input_was_unknown) tymod.ID_ANY else tymod.ID_UNKNOWN;
    }

    /// Look up `prop_name` on the apparent type of `obj_ty`.  Handles:
    ///   - union: every member must have the property; result is the
    ///     union of property types (we approximate with the first
    ///     non-unknown).
    ///   - intersection: any member's property fires.
    ///   - type_ref to lib (Promise / Array / etc.): synthesised methods.
    ///   - type_ref to user alias / interface / class: look up the
    ///     resolved declared type's members.
    ///   - type_ref to type parameter: chase the constraint (apparent
    ///     type) and re-do the lookup.
    ///   - array_t / readonly_array_t / tuple_t: Array.prototype.
    ///   - object_t: direct property lookup.
    fn memberOnApparentType(self: *Checker, obj_ty: TypeId, prop_name: []const u8, obj_node: NodeIndex) TypeId {
        const obj = self.store.get(obj_ty);
        // Remember if input obj_ty is unknown/error so we return `any`
        // instead of `unknown` at the end, following the "unknown source → any"
        // assumption (fixes ~14k coverage-gap cases systematically).
        const input_was_unknown = obj_ty.eq(tymod.ID_UNKNOWN) or obj_ty.eq(tymod.ID_ERROR);
        // Composite receivers: walk members.
        if (obj.kind == .union_t) {
            // Per TS: every union member must have the property.  We
            // union each member's projected type — `({type:'A'} |
            // {type:'B'}).type` becomes `'A' | 'B'`.  Nullish members
            // (null/undefined/void) are skipped so `(T | null).prop`
            // is just `prop_of_T` (matching TSC's optional-chain
            // model — explicit `?.` access is required to safely
            // reach the prop when the receiver could be nullish).
            var buf: [16]TypeId = undefined;
            var n: usize = 0;
            for (self.store.idsOf(obj.list_data)) |m| {
                if (n >= buf.len) break;
                const mk = self.store.get(m).kind;
                if (mk == .null_t or mk == .undefined_t or mk == .void_t) continue;
                const t = self.memberOnApparentType(m, prop_name, obj_node);
                if (tymod.isUnknown(&self.store, t)) return if (input_was_unknown) tymod.ID_ANY else tymod.ID_UNKNOWN;
                buf[n] = t;
                n += 1;
            }
            if (n == 0) return if (input_was_unknown) tymod.ID_ANY else tymod.ID_UNKNOWN;
            if (n == 1) return buf[0];
            return self.store.unionOf(buf[0..n]) catch if (input_was_unknown) tymod.ID_ANY else tymod.ID_UNKNOWN;
        }
        if (obj.kind == .intersection_t) {
            for (self.store.idsOf(obj.list_data)) |m| {
                const t = self.memberOnApparentType(m, prop_name, obj_node);
                if (!tymod.isUnknown(&self.store, t)) return t;
            }
            return if (input_was_unknown) tymod.ID_ANY else tymod.ID_UNKNOWN;
        }
        // Array.prototype.
        if (obj.kind == .array_t or obj.kind == .readonly_array_t or obj.kind == .tuple_t) {
            const elem: TypeId = if (self.arrayMethodElementTypeOf(obj_ty)) |et| et else tymod.ID_UNKNOWN;
            return self.arrayPrototypeProperty(prop_name, elem);
        }
        // Lib type_ref methods.
        if (obj.kind == .type_ref) {
            // Snapshot name before any type-adding calls — libTypeRefProperty/resolveDeclaredType
            // may grow types.items, invalidating the `obj` pointer obtained from store.get().
            const ref_name = obj.name;
            if (self.libTypeRefProperty(obj_ty, prop_name)) |ty| return ty;
            // User-declared types — resolve via the declared cache.
            if (self.resolveDeclaredType(ref_name)) |resolved| {
                if (!resolved.eq(obj_ty)) {
                    // Apply generic type arg substitution: e.g. TaggedPair<number> →
                    // substitute T=number throughout the resolved structural type before lookup.
                    const subst = self.applyDeclTypeArgs(obj_ty, ref_name, resolved);
                    const t = self.memberOnApparentType(subst, prop_name, obj_node);
                    if (!tymod.isUnknown(&self.store, t)) return t;
                }
            }
            // Polymorphic `this` type: resolve member access via the enclosing class.
            if (std.mem.eql(u8, ref_name, "this")) {
                if (self.thisEnclosingClassType(obj_node)) |class_ty| {
                    if (class_ty.eq(tymod.ID_UNKNOWN)) {
                        // Class is still being built (sentinel) — memberOnApparentType
                        // would return any, masking the real type.  Directly scan the
                        // class body for an annotated property declaration instead.
                        if (self.thisClassDirectPropLookup(obj_node, prop_name)) |direct_ty| {
                            return direct_ty;
                        }
                    } else {
                        const t = self.memberOnApparentType(class_ty, prop_name, obj_node);
                        if (!tymod.isUnknown(&self.store, t)) return t;
                    }
                }
            }
            // Type parameter: chase constraint (apparent type).
            const constraint = self.typeParameterConstraintFromName(ref_name, obj_node);
            if (constraint) |c| {
                if (!c.eq(obj_ty)) {
                    return self.memberOnApparentType(c, prop_name, obj_node);
                }
            }
            // `typeof X` where X is an enum or namespace star import — look up member
            // in the enum object or the imported module respectively.
            if (std.mem.startsWith(u8, ref_name, "typeof ")) {
                const inner_name = ref_name["typeof ".len..];
                // Expando function property: `function foo(){} foo.x = 1` —
                // `foo.x` (and the property key `x`) has the widened assigned
                // value type.  Handled here so both read accesses and write
                // targets (via inferPropertyIdent) resolve.
                if (self.expando_fns.get(inner_name)) |elist| {
                    for (elist.items) |ep| {
                        if (!std.mem.eql(u8, ep.name, prop_name)) continue;
                        if (ep.value == .none) break;
                        // Salsa naming: a function expression assigned to an
                        // expando prop becomes a named entity (`typeof Inner`);
                        // a nested object literal is referenced by its path
                        // (`typeof Host.UserMetrics`).
                        switch (self.ast_ref.nodeTag(ep.value)) {
                            .fn_expr, .async_fn_expr, .generator_fn_expr,
                            .async_generator_fn_expr, .class_expr => {
                                const tn = std.fmt.allocPrint(self.gpa, "typeof {s}", .{prop_name}) catch break;
                                return self.store.typeRef(tn, &.{}) catch tymod.ID_ANY;
                            },
                            .object_literal => {
                                if (self.isEmptyObjectLiteral(ep.value)) {
                                    const tn = std.fmt.allocPrint(self.gpa, "typeof {s}.{s}", .{ inner_name, prop_name }) catch break;
                                    return self.store.typeRef(tn, &.{}) catch tymod.ID_ANY;
                                }
                            },
                            else => {},
                        }
                        const raw = self.typeOf(ep.value);
                        return switch (self.store.get(raw).kind) {
                            .string_literal => tymod.ID_STRING,
                            .number_literal => tymod.ID_NUMBER,
                            .bigint_literal => tymod.ID_BIGINT,
                            .boolean_literal => tymod.ID_BOOLEAN,
                            else => raw,
                        };
                    }
                }
                if (self.enum_kinds.get(inner_name) != null) {
                    if (self.buildEnumObjectType(inner_name)) |obj_type| {
                        const ot2 = self.store.get(obj_type);
                        if (ot2.kind == .object_t) {
                            for (self.store.propsOf(ot2.object_props)) |p| {
                                if (std.mem.eql(u8, p.name, prop_name)) return p.type_id;
                            }
                        }
                    }
                }
                if (self.namespace_import_map.get(inner_name)) |mod_spec| {
                    if (self.inferMemberOnNamespace(mod_spec, prop_name)) |resolved| return resolved;
                }
                // `typeof ClassName` — look up static member on the class.
                if (self.type_decl_nodes.get(inner_name)) |cls_decl| {
                    if (self.ast_ref.nodeTag(cls_decl) == .class_decl) {
                        const st = self.buildClassStaticType(cls_decl, inner_name);
                        if (!st.eq(tymod.ID_UNKNOWN)) {
                            const t = self.memberOnApparentType(st, prop_name, obj_node);
                            if (!tymod.isUnknown(&self.store, t)) return t;
                        }
                    }
                }
            }
            return tymod.ID_ANY;
        }
        if (obj.kind == .object_t) {
            for (self.store.propsOf(obj.object_props)) |p| {
                if (std.mem.eql(u8, p.name, prop_name)) {
                    if (p.optional) {
                        return self.store.unionOf(&.{ p.type_id, tymod.ID_UNDEFINED }) catch p.type_id;
                    }
                    return p.type_id;
                }
            }
        }
        // String prototype.
        if (obj.kind == .string or obj.kind == .string_literal) {
            if (self.stringPrototypeProperty(prop_name)) |ty| return ty;
        }
        // Number prototype.
        if (obj.kind == .number or obj.kind == .number_literal) {
            if (self.numberPrototypeProperty(prop_name)) |ty| return ty;
        }
        // Fallback: for non-primitive types where the property wasn't found,
        // return `any` to match TypeScript's permissive behavior on missing
        // properties (e.g., class instance members not in the model).
        // For primitives (string/number/boolean/etc.) whose prototype was fully
        // checked above, a missing property stays unknown.
        return switch (obj.kind) {
            .string, .string_literal, .number, .number_literal,
            .boolean, .boolean_literal, .null_t, .undefined_t,
            .void_t, .never, .bigint, .bigint_literal, .symbol => tymod.ID_UNKNOWN,
            else => tymod.ID_ANY,
        };
    }

    /// Walk to the enclosing scope and find a `ts_type_parameter`
    /// named `name`, then return its constraint TypeId.
    fn typeParameterConstraintFromName(self: *Checker, name: []const u8, at_node: NodeIndex) ?TypeId {
        if (at_node == .none) return null;
        return self.resolveTypeParameterConstraint(at_node, name);
    }

    /// True when `ty_node` is a `ts_type_reference` whose name resolves
    /// to a TS type parameter declared in enclosing scope.
    pub fn typeAnnotationIsTypeParameter(self: *Checker, ty_node: NodeIndex) bool {
        var n = ty_node;
        if (n == .none) return false;
        if (self.ast_ref.nodeTag(n) == .ts_type_annotation) n = self.ast_ref.nodeData(n).lhs;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .ts_type_reference) return false;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
        return self.findTypeParameterDecl(n, name) != null;
    }

    /// For a `ts_type_reference` to a type parameter, return its constraint
    /// TypeId (or `ID_UNKNOWN` if unconstrained).  Returns null when the
    /// node is not a type-parameter reference.
    pub fn typeParameterConstraintOf(self: *Checker, ty_node: NodeIndex) ?TypeId {
        var n = ty_node;
        if (n == .none) return null;
        if (self.ast_ref.nodeTag(n) == .ts_type_annotation) n = self.ast_ref.nodeData(n).lhs;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .ts_type_reference) return null;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
        const tp = self.findTypeParameterDecl(n, name) orelse return null;
        // ts_type_parameter encodes: main_token = name, lhs = constraint
        // (or .none), rhs = default (or .none).
        const tp_data = self.ast_ref.nodeData(tp);
        if (tp_data.lhs == .none) return tymod.ID_UNKNOWN;
        return self.resolveTypeNode(tp_data.lhs);
    }

    /// Returns the AST node of the type-parameter's constraint
    /// expression (the `X` in `T extends X`), or `null` when there
    /// is none.  Lets callers distinguish "no constraint" from
    /// "constraint resolves to unknown".
    pub fn typeParameterConstraintNodeOf(self: *Checker, ty_node: NodeIndex) ?NodeIndex {
        var n = ty_node;
        if (n == .none) return null;
        if (self.ast_ref.nodeTag(n) == .ts_type_annotation) n = self.ast_ref.nodeData(n).lhs;
        while (self.ast_ref.nodeTag(n) == .ts_parenthesized_type) n = self.ast_ref.nodeData(n).lhs;
        if (self.ast_ref.nodeTag(n) != .ts_type_reference) return null;
        const name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(n));
        const tp = self.findTypeParameterDecl(n, name) orelse return null;
        const tp_data = self.ast_ref.nodeData(tp);
        if (tp_data.lhs == .none) return null;
        return tp_data.lhs;
    }

    /// Find a `ts_type_parameter` AST node whose name matches and is
    /// declared in an enclosing scope of `ref_node`.
    fn findTypeParameterDecl(self: *Checker, ref_node: NodeIndex, name: []const u8) ?NodeIndex {
        const tree = self.ast_ref;
        const parents = self.semantic.parent_indices;
        const rni = ref_node.toInt();
        if (rni >= parents.len) return null;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var anc_buf: [16]u32 = undefined;
        var nanc: usize = 0;
        var p = parents[rni];
        while (p != NONE and p < parents.len and nanc < anc_buf.len) : (p = parents[p]) {
            anc_buf[nanc] = p;
            nanc += 1;
        }
        const ref_main_tok = tree.nodeMainToken(ref_node);
        const ref_pos = tree.tokenStart(ref_main_tok);
        // Pick the INNERMOST type parameter (highest tp_pos) — matches
        // TS's shadowing rules where an inner `<T>` shadows an outer.
        var best: NodeIndex = .none;
        var best_pos: u32 = 0;
        for (self.type_param_nodes.items) |ni| {
            if (!std.mem.eql(u8, tree.tokenText(tree.nodeMainToken(ni)), name)) continue;
            const tp_pos = tree.tokenStart(tree.nodeMainToken(ni));
            if (tp_pos >= ref_pos) continue;
            const tpni = ni.toInt();
            if (tpni >= parents.len) continue;
            const tp_parent = parents[tpni];
            if (tp_parent == NONE) continue;
            var tp_p = tp_parent;
            var in_scope = false;
            while (tp_p != NONE and @as(usize, tp_p) < parents.len) : (tp_p = parents[tp_p]) {
                for (anc_buf[0..nanc]) |anc| {
                    if (anc == tp_p) { in_scope = true; break; }
                }
                if (in_scope) break;
            }
            if (!in_scope) continue;
            if (best == .none or tp_pos > best_pos) {
                best = ni;
                best_pos = tp_pos;
            }
        }
        if (best == .none) return null;
        return best;
    }

    /// Substitute type arguments into a generic type-alias body.
    /// Returns null when the alias has no type parameters or the
    /// use-site has no type args.  Otherwise returns the substituted
    /// TypeId (cloned through the type store).
    fn substituteAliasArgs(self: *Checker, decl: NodeIndex, ref_node: NodeIndex, alias_body: TypeId) ?TypeId {
        const tad = self.ast_ref.extraData(ast.TypeAliasData, @intFromEnum(self.ast_ref.nodeData(decl).lhs));
        if (tad.type_params_end <= tad.type_params) return null;
        const ref_data = self.ast_ref.nodeData(ref_node);
        const arg_range = self.safeSubRange(ref_data.rhs) orelse return null;
        if (arg_range.end <= arg_range.start) return null;
        // Build substitution map: param name → TypeId.
        var keys_buf: [4][]const u8 = undefined;
        var vals_buf: [4]TypeId = undefined;
        var nsub: usize = 0;
        const tp_count = tad.type_params_end - tad.type_params;
        const arg_count = arg_range.end - arg_range.start;
        const n = @min(@min(tp_count, arg_count), keys_buf.len);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tp: NodeIndex = @enumFromInt(self.ast_ref.extra_data[tad.type_params + i]);
            const arg: NodeIndex = @enumFromInt(self.ast_ref.extra_data[arg_range.start + i]);
            if (self.ast_ref.nodeTag(tp) != .ts_type_parameter) continue;
            keys_buf[nsub] = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp));
            vals_buf[nsub] = self.resolveTypeNode(arg);
            nsub += 1;
        }
        if (nsub == 0) return null;
        return self.substituteTypeId(alias_body, keys_buf[0..nsub], vals_buf[0..nsub]);
    }

    /// For a `type_ref` with args (e.g. `TaggedPair<number>`), apply the type
    /// args to the resolved structural body (`body`).  Extracts type param names
    /// from the user-declared interface/class AST node, then calls substituteTypeId
    /// to substitute each arg.  Returns `body` unchanged when there are no args or
    /// no matching type params.
    fn applyDeclTypeArgs(self: *Checker, ref_id: TypeId, name: []const u8, body: TypeId) TypeId {
        const tr = self.store.get(ref_id);
        const args_slice = self.store.idsOf(tr.list_data);
        if (args_slice.len == 0) return body;

        const decl = self.type_decl_nodes.get(name) orelse return body;
        var tp_start: u32 = 0;
        var tp_end: u32 = 0;
        switch (self.ast_ref.nodeTag(decl)) {
            .ts_interface_decl => {
                const d = self.ast_ref.nodeData(decl);
                const id = self.ast_ref.extraData(ast.InterfaceData, @intFromEnum(d.lhs));
                tp_start = id.type_params;
                tp_end = id.type_params_end;
            },
            .class_decl => {
                const d = self.ast_ref.nodeData(decl);
                const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(d.lhs));
                tp_start = cd.type_params;
                tp_end = cd.type_params_end;
            },
            else => return body,
        }
        if (tp_end <= tp_start) return body;

        // Snapshot args before substituteTypeId may realloc the type_id_pool.
        var args_buf: [8]TypeId = undefined;
        const arg_count = @min(args_slice.len, args_buf.len);
        @memcpy(args_buf[0..arg_count], args_slice[0..arg_count]);

        var keys_buf: [8][]const u8 = undefined;
        var vals_buf: [8]TypeId = undefined;
        var nsub: usize = 0;
        const n = @min(@min(tp_end - tp_start, @as(u32, @intCast(arg_count))), @as(u32, keys_buf.len));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tp: NodeIndex = @enumFromInt(self.ast_ref.extra_data[tp_start + i]);
            if (self.ast_ref.nodeTag(tp) != .ts_type_parameter) continue;
            keys_buf[nsub] = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(tp));
            vals_buf[nsub] = args_buf[i];
            nsub += 1;
        }
        if (nsub == 0) return body;
        return self.substituteTypeId(body, keys_buf[0..nsub], vals_buf[0..nsub]);
    }

    /// Walk a TypeId and replace any `type_ref` whose name matches a
    /// substitution key.  Recurses through composites (union, intersection,
    /// array, tuple, object props).  Returns the original id when no
    /// substitution happened.
    fn substituteTypeId(self: *Checker, id: TypeId, keys: []const []const u8, vals: []const TypeId) TypeId {
        // Structural substitution recurses through union/intersection/array/object/
        // function members; a self-referential instantiation (bluebird's
        // `then<U>(…): Bluebird<U>` whose params substitute through `Resolvable<U>
        // = U | PromiseLike<U>`) can loop unboundedly. Share the resolve depth
        // budget and bail to the type unchanged on overflow.
        if (self.resolve_depth >= 256) return id;
        self.resolve_depth += 1;
        defer self.resolve_depth -= 1;
        const t = self.store.get(id);
        switch (t.kind) {
            // A bare type parameter (`T` resolved to its own param type, e.g. the
            // element of `Readonly<T>[]` after Readonly unwraps) — substitute by
            // name. Without this, `Alias<Arg>['prop']` leaves T unsubstituted.
            .type_param => {
                for (keys, vals) |k, v| {
                    if (std.mem.eql(u8, k, t.name)) return v;
                }
                return id;
            },
            .type_ref => {
                // Snapshot name and list_data NOW — recursive substituteTypeId calls
                // below can realloc types.items, invalidating the `t` pointer.
                const ref_name = t.name;
                const ref_list = t.list_data;
                for (keys, vals) |k, v| {
                    if (std.mem.eql(u8, k, ref_name)) return v;
                }
                // Substitute through type args (e.g. `Promise<T>`).
                const args_slice = self.store.idsOf(ref_list);
                if (args_slice.len == 0) return id;
                var args_buf: [8]TypeId = undefined;
                if (args_slice.len > args_buf.len) return id;
                // Snapshot args before recursing: substituteTypeId can append to
                // type_id_pool (typeRef/unionOf/…), reallocating the slice we borrow.
                @memcpy(args_buf[0..args_slice.len], args_slice);
                const args = args_buf[0..args_slice.len];
                var new_args_buf: [8]TypeId = undefined;
                var changed = false;
                for (args, 0..) |a, i| {
                    new_args_buf[i] = self.substituteTypeId(a, keys, vals);
                    if (!new_args_buf[i].eq(a)) changed = true;
                }
                if (!changed) return id;
                return self.store.typeRef(ref_name, new_args_buf[0..args.len]) catch id;
            },
            .union_t => return self.substituteList(id, t, keys, vals, .union_t),
            .intersection_t => return self.substituteList(id, t, keys, vals, .intersection_t),
            .array_t, .readonly_array_t, .tuple_t, .rest_t => return self.substituteArrayLike(id, t, keys, vals),
            .object_t => return self.substituteObject(id, t, keys, vals),
            .function_t => {
                // Substitute type params into each signature's param types and return type.
                const sigs_slice = self.store.signaturesOf(t.signatures);
                if (sigs_slice.len == 0) return id;
                var new_sigs_buf: [4]tymod.Signature = undefined;
                if (sigs_slice.len > new_sigs_buf.len) return id;
                // Snapshot list header + flags BEFORE any store mutation can
                // invalidate `t`.
                const old_list = t.signatures;
                const was_overload_set = t.is_overload_set;
                // Snapshot the signatures BEFORE recursing: substituteTypeId below
                // can appendSignatureParams/appendSignatures, reallocating the
                // pools and invalidating any slice still borrowed from them.
                var sigs_buf: [4]tymod.Signature = undefined;
                @memcpy(sigs_buf[0..sigs_slice.len], sigs_slice);
                const sigs = sigs_buf[0..sigs_slice.len];
                var changed = false;
                for (sigs, 0..) |sig, si| {
                    const op_slice = self.store.signatureParamsOf(sig);
                    var op_buf: [8]TypeId = undefined;
                    if (op_slice.len > op_buf.len) return id;
                    // Same hazard: copy the params out of signature_param_pool
                    // before the substitution recursion can grow (realloc) it.
                    @memcpy(op_buf[0..op_slice.len], op_slice);
                    const old_params = op_buf[0..op_slice.len];
                    var new_params_buf: [8]TypeId = undefined;
                    for (old_params, 0..) |p, pi| {
                        new_params_buf[pi] = self.substituteTypeId(p, keys, vals);
                        if (!new_params_buf[pi].eq(p)) changed = true;
                    }
                    const new_ret = self.substituteTypeId(sig.return_type, keys, vals);
                    if (!new_ret.eq(sig.return_type)) changed = true;
                    // Snapshot names + optional flags before appendSignatureParamsFull —
                    // that call may grow the pools, invalidating borrowed slices.
                    const old_names_slice = self.store.signatureParamNamesOf(sig);
                    var old_names_buf: [8][]const u8 = undefined;
                    if (old_names_slice.len > old_names_buf.len) return id;
                    @memcpy(old_names_buf[0..old_names_slice.len], old_names_slice);
                    const old_names = old_names_buf[0..old_names_slice.len];
                    const old_opts_slice = self.store.signatureParamOptionalsOf(sig);
                    var old_opts_buf: [8]bool = undefined;
                    var old_opts: []const bool = &.{};
                    if (old_opts_slice.len <= old_opts_buf.len) {
                        @memcpy(old_opts_buf[0..old_opts_slice.len], old_opts_slice);
                        old_opts = old_opts_buf[0..old_opts_slice.len];
                    }
                    const pr = self.store.appendSignatureParamsFull(new_params_buf[0..old_params.len], old_names, old_opts) catch return id;
                    // Preserve all other signature fields (is_construct, predicate,
                    // assertion) — only the param range and return type change.
                    var ns = sig;
                    ns.params_start = pr.start;
                    ns.params_end = pr.end;
                    ns.return_type = new_ret;
                    new_sigs_buf[si] = ns;
                }
                if (!changed) return id;
                const sl = self.store.appendSignatures(new_sigs_buf[0..sigs.len]) catch return id;
                // Carry per-signature type-param prefixes (`<U>`) to the new
                // pool slots — the registry is keyed by pool index.
                for (0..sigs.len) |k| {
                    if (self.sig_type_params.get(old_list.start + @as(u32, @intCast(k)))) |prefix| {
                        const dst = sl.start + @as(u32, @intCast(k));
                        if (!self.sig_type_params.contains(dst)) {
                            const dup = self.gpa.dupe(u8, prefix) catch break;
                            self.sig_type_params.put(self.gpa, dst, dup) catch self.gpa.free(dup);
                        }
                    }
                }
                return self.store.add(.{ .kind = .function_t, .signatures = sl, .is_overload_set = was_overload_set }) catch id;
            },
            else => return id,
        }
    }

    fn substituteList(self: *Checker, id: TypeId, t: *const tymod.Type, keys: []const []const u8, vals: []const TypeId, kind: tymod.TypeKind) TypeId {
        const members_slice = self.store.idsOf(t.list_data);
        if (members_slice.len == 0) return id;
        var members_buf: [16]TypeId = undefined;
        if (members_slice.len > members_buf.len) return id;
        // Snapshot before recursing — substituteTypeId can realloc type_id_pool.
        @memcpy(members_buf[0..members_slice.len], members_slice);
        const members = members_buf[0..members_slice.len];
        var new_buf: [16]TypeId = undefined;
        var changed = false;
        for (members, 0..) |m, i| {
            new_buf[i] = self.substituteTypeId(m, keys, vals);
            if (!new_buf[i].eq(m)) changed = true;
        }
        if (!changed) return id;
        if (kind == .union_t) return self.store.unionOf(new_buf[0..members.len]) catch id;
        return self.store.intersectionOf(new_buf[0..members.len]) catch id;
    }

    fn substituteArrayLike(self: *Checker, id: TypeId, t: *const tymod.Type, keys: []const []const u8, vals: []const TypeId) TypeId {
        const elems_slice = self.store.idsOf(t.list_data);
        if (elems_slice.len == 0) return id;
        if (t.kind == .tuple_t) {
            var elems_buf: [16]TypeId = undefined;
            if (elems_slice.len > elems_buf.len) return id;
            // Snapshot before recursing — substituteTypeId can realloc type_id_pool.
            @memcpy(elems_buf[0..elems_slice.len], elems_slice);
            const elems = elems_buf[0..elems_slice.len];
            var new_buf: [16]TypeId = undefined;
            var changed = false;
            for (elems, 0..) |m, i| {
                new_buf[i] = self.substituteTypeId(m, keys, vals);
                if (!new_buf[i].eq(m)) changed = true;
            }
            if (!changed) return id;
            return self.store.tupleOf(new_buf[0..elems.len]) catch id;
        }
        // Copy the element id out before recursing (the borrowed slice dangles).
        const elem0 = elems_slice[0];
        const new_elem = self.substituteTypeId(elem0, keys, vals);
        if (new_elem.eq(elem0)) return id;
        if (t.kind == .readonly_array_t) return self.store.readonlyArrayOf(new_elem) catch id;
        if (t.kind == .rest_t) return self.store.restOf(new_elem) catch id;
        return self.store.arrayOf(new_elem) catch id;
    }

    fn substituteObject(self: *Checker, id: TypeId, t: *const tymod.Type, keys: []const []const u8, vals: []const TypeId) TypeId {
        const props_slice = self.store.propsOf(t.object_props);
        if (props_slice.len == 0) return id;
        var props_buf: [16]tymod.ObjectProp = undefined;
        if (props_slice.len > props_buf.len) return id;
        // Snapshot before recursing — substituteTypeId can realloc object_prop_pool
        // (a nested object substitution), invalidating the borrowed `props` slice.
        @memcpy(props_buf[0..props_slice.len], props_slice);
        const props = props_buf[0..props_slice.len];
        var new_buf: [16]tymod.ObjectProp = undefined;
        var changed = false;
        for (props, 0..) |p, i| {
            const new_pty = self.substituteTypeId(p.type_id, keys, vals);
            new_buf[i] = .{
                .name = p.name,
                .type_id = new_pty,
                .optional = p.optional,
                .readonly = p.readonly,
                .is_method = p.is_method,
                .is_fn_property = p.is_fn_property,
            };
            if (!new_pty.eq(p.type_id)) changed = true;
        }
        if (!changed) return id;
        return self.store.objectOf(new_buf[0..props.len]) catch id;
    }

    /// Look up a property on a lib type_ref (Promise / Array / Set /
    /// Map).  Returns null when the type isn't recognised or doesn't
    /// have the named property modeled.
    fn libTypeRefProperty(self: *Checker, ref_ty: TypeId, name: []const u8) ?TypeId {
        const t = self.store.get(ref_ty);
        if (t.kind != .type_ref) return null;
        const args = self.store.idsOf(t.list_data);
        if (std.mem.eql(u8, t.name, "Array") or std.mem.eql(u8, t.name, "ReadonlyArray")) {
            const elem = if (args.len > 0) args[0] else tymod.ID_UNKNOWN;
            return self.arrayPrototypeProperty(name, elem);
        }
        if (std.mem.eql(u8, t.name, "Promise")) {
            const inner = if (args.len > 0) args[0] else tymod.ID_UNKNOWN;
            return self.promisePrototypeProperty(name, inner);
        }
        // Well-known symbols: `Symbol.iterator` etc. are `unique symbol`.
        if (std.mem.eql(u8, t.name, "SymbolConstructor")) {
            const well_known = [_][]const u8{
                "iterator",     "asyncIterator", "hasInstance",   "isConcatSpreadable",
                "match",        "matchAll",      "replace",       "search",
                "species",      "split",         "toPrimitive",   "toStringTag",
                "unscopables",  "dispose",       "asyncDispose",  "metadata",
            };
            for (well_known) |wk| {
                if (std.mem.eql(u8, name, wk)) {
                    return self.store.typeRef("unique symbol", &.{}) catch null;
                }
            }
            return null;
        }
        const struct_key: ?[]const u8 = if (std.mem.eql(u8, t.name, "Math"))
            "__Math_struct"
        else if (std.mem.eql(u8, t.name, "JSON"))
            "__JSON_struct"
        else if (std.mem.eql(u8, t.name, "ArrayConstructor"))
            "__Array_struct"
        else if (std.mem.eql(u8, t.name, "ObjectConstructor"))
            "__Object_struct"
        else if (std.mem.eql(u8, t.name, "console") or std.mem.eql(u8, t.name, "Console"))
            "__console_struct"
        else
            null;
        if (struct_key) |sk| {
            if (self.global_value_types.get(sk)) |struct_ty| {
                if (self.propertyTypeOfTypeId(struct_ty, name)) |prop_ty| return prop_ty;
            }
            return null;
        }
        if (std.mem.eql(u8, t.name, "IArguments")) {
            if (std.mem.eql(u8, name, "length")) return tymod.ID_NUMBER;
            if (std.mem.eql(u8, name, "callee")) return self.store.typeRef("Function", &.{}) catch null;
            return tymod.ID_ANY;
        }
        return null;
    }

    fn promisePrototypeProperty(self: *Checker, name: []const u8, _: TypeId) ?TypeId {
        // The Promise<T> chain methods .then/.catch/.finally all return
        // Promise<unknown> (loose approximation, doesn't track resolved
        // handler return types).  Each is a function_t that propagates
        // chains so 'promise.then(...).catch(...)' is also Promise.
        const unknown_promise = self.store.typeRef("Promise", &.{tymod.ID_UNKNOWN}) catch return null;
        if (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch") or
            std.mem.eql(u8, name, "finally"))
        {
            return self.makeNullaryFn(unknown_promise);
        }
        return null;
    }

    /// Lookup an Array.prototype method by name and return its
    /// (function or scalar) type.  Returns ID_UNKNOWN for properties
    /// we don't model.
    fn arrayPrototypeProperty(self: *Checker, name: []const u8, elem: TypeId) TypeId {
        // length / indexOf / lastIndexOf return numbers.
        if (std.mem.eql(u8, name, "length")) return tymod.ID_NUMBER;
        // T | undefined returners.
        if (std.mem.eql(u8, name, "shift") or std.mem.eql(u8, name, "pop") or
            std.mem.eql(u8, name, "at") or std.mem.eql(u8, name, "find") or
            std.mem.eql(u8, name, "findLast"))
        {
            const opt = self.store.unionOf(&.{ elem, tymod.ID_UNDEFINED }) catch return tymod.ID_UNKNOWN;
            return self.makeNullaryFn(opt);
        }
        // T[] returners.
        if (std.mem.eql(u8, name, "slice") or std.mem.eql(u8, name, "concat") or
            std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "reverse") or
            std.mem.eql(u8, name, "toSorted") or std.mem.eql(u8, name, "toReversed") or
            std.mem.eql(u8, name, "splice"))
        {
            const arr_ty = self.store.arrayOf(elem) catch return tymod.ID_UNKNOWN;
            return self.makeNullaryFn(arr_ty);
        }
        // boolean returners.
        if (std.mem.eql(u8, name, "includes") or std.mem.eql(u8, name, "every") or
            std.mem.eql(u8, name, "some"))
        {
            return self.makeNullaryFn(tymod.ID_BOOLEAN);
        }
        // push/unshift: `(...items: T[]) => number`.
        if (std.mem.eql(u8, name, "push") or std.mem.eql(u8, name, "unshift")) {
            return self.makeArrayMutatorFn(elem);
        }
        // number returners.
        if (std.mem.eql(u8, name, "indexOf") or std.mem.eql(u8, name, "lastIndexOf") or
            std.mem.eql(u8, name, "findIndex") or std.mem.eql(u8, name, "findLastIndex"))
        {
            return self.makeNullaryFn(tymod.ID_NUMBER);
        }
        // string returners.
        if (std.mem.eql(u8, name, "join") or std.mem.eql(u8, name, "toString") or
            std.mem.eql(u8, name, "toLocaleString"))
        {
            return self.makeNullaryFn(tymod.ID_STRING);
        }
        return tymod.ID_ANY;
    }

    fn stringPrototypeProperty(self: *Checker, name: []const u8) ?TypeId {
        if (std.mem.eql(u8, name, "length")) return tymod.ID_NUMBER;
        // string returners
        if (std.mem.eql(u8, name, "charAt") or
            std.mem.eql(u8, name, "concat") or std.mem.eql(u8, name, "slice") or
            std.mem.eql(u8, name, "substring") or std.mem.eql(u8, name, "toUpperCase") or
            std.mem.eql(u8, name, "toLowerCase") or std.mem.eql(u8, name, "trim") or
            std.mem.eql(u8, name, "trimStart") or std.mem.eql(u8, name, "trimEnd") or
            std.mem.eql(u8, name, "repeat") or std.mem.eql(u8, name, "replace") or
            std.mem.eql(u8, name, "replaceAll") or std.mem.eql(u8, name, "normalize") or
            std.mem.eql(u8, name, "padStart") or std.mem.eql(u8, name, "padEnd") or
            std.mem.eql(u8, name, "at") or std.mem.eql(u8, name, "toString") or
            std.mem.eql(u8, name, "valueOf"))
        {
            return self.makeNullaryFn(tymod.ID_STRING);
        }
        // number returners
        if (std.mem.eql(u8, name, "charCodeAt") or std.mem.eql(u8, name, "codePointAt") or
            std.mem.eql(u8, name, "indexOf") or std.mem.eql(u8, name, "lastIndexOf") or
            std.mem.eql(u8, name, "search"))
        {
            return self.makeNullaryFn(tymod.ID_NUMBER);
        }
        // boolean returners
        if (std.mem.eql(u8, name, "includes") or std.mem.eql(u8, name, "startsWith") or
            std.mem.eql(u8, name, "endsWith"))
        {
            return self.makeNullaryFn(tymod.ID_BOOLEAN);
        }
        // string[] returners
        if (std.mem.eql(u8, name, "split")) {
            const arr = self.store.arrayOf(tymod.ID_STRING) catch return null;
            return self.makeNullaryFn(arr);
        }
        // RegExpMatchArray | null returners (match/matchAll)
        if (std.mem.eql(u8, name, "match") or std.mem.eql(u8, name, "matchAll")) {
            const arr = self.store.arrayOf(tymod.ID_STRING) catch tymod.ID_UNKNOWN;
            const nullable = self.store.unionOf(&.{ arr, tymod.ID_NULL }) catch arr;
            return self.makeNullaryFn(nullable);
        }
        return null;
    }

    fn numberPrototypeProperty(self: *Checker, name: []const u8) ?TypeId {
        // toString/toFixed/toExponential/toPrecision: (radix?: number) => string
        if (std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "toFixed") or
            std.mem.eql(u8, name, "toExponential") or std.mem.eql(u8, name, "toPrecision"))
        {
            const pname: []const u8 = if (std.mem.eql(u8, name, "toString")) "radix" else "fractionDigits";
            return self.makeNamedOptionalFn(tymod.ID_NUMBER, pname, tymod.ID_STRING);
        }
        if (std.mem.eql(u8, name, "toLocaleString")) return self.makeNullaryFn(tymod.ID_STRING);
        if (std.mem.eql(u8, name, "valueOf")) return self.makeNullaryFn(tymod.ID_NUMBER);
        return null;
    }

    /// `(pname?: T) => R` — single named optional parameter.
    fn makeNamedOptionalFn(self: *Checker, param: TypeId, pname: []const u8, ret: TypeId) TypeId {
        var pbuf = [_]tymod.TypeId{param};
        var nbuf = [_][]const u8{pname};
        var obuf = [_]bool{true};
        const pr = self.store.appendSignatureParamsFull(&pbuf, &nbuf, &obuf) catch
            return self.makeNullaryFn(ret);
        const sig: tymod.Signature = .{
            .params_start = pr.start,
            .params_end = pr.end,
            .return_type = ret,
        };
        return self.store.functionType(sig) catch self.makeNullaryFn(ret);
    }

    fn makeNullaryFn(self: *Checker, ret: TypeId) TypeId {
        const param_range = self.store.appendSignatureParams(&.{}, &.{}) catch return tymod.ID_UNKNOWN;
        const sig: tymod.Signature = .{
            .params_start = param_range.start,
            .params_end = param_range.end,
            .return_type = ret,
        };
        return self.store.functionType(sig) catch tymod.ID_UNKNOWN;
    }

    /// `(...items: <elem>[]) => number` — the signature of Array.push/unshift.
    fn makeArrayMutatorFn(self: *Checker, elem: TypeId) TypeId {
        const items_ty = self.store.arrayOf(elem) catch return self.makeNullaryFn(tymod.ID_NUMBER);
        var pbuf = [_]TypeId{items_ty};
        var nbuf = [_][]const u8{"items"};
        var obuf = [_]bool{false};
        const pr = self.store.appendSignatureParamsFull(&pbuf, &nbuf, &obuf) catch
            return self.makeNullaryFn(tymod.ID_NUMBER);
        const sig: tymod.Signature = .{
            .params_start = pr.start,
            .params_end = pr.end,
            .return_type = tymod.ID_NUMBER,
            .rest_param_index = 0,
        };
        return self.store.functionType(sig) catch self.makeNullaryFn(tymod.ID_NUMBER);
    }

    /// A function's explicit `this: T` parameter type, or null when absent.
    /// The `this` param is a leading identifier named `this` with an annotation;
    /// it is not a real runtime parameter.
    fn functionThisParamType(self: *Checker, fn_node: NodeIndex) ?TypeId {
        const data = self.ast_ref.nodeData(fn_node);
        if (data.lhs == .none) return null;
        const fd = self.ast_ref.extraData(ast.FnData, @intFromEnum(data.lhs));
        if (fd.params >= fd.params_end or fd.params_end > self.ast_ref.extra_data.len) return null;
        const first: NodeIndex = @enumFromInt(self.ast_ref.extra_data[fd.params]);
        if (self.ast_ref.nodeTag(first) != .identifier) return null;
        if (!std.mem.eql(u8, self.ast_ref.tokenText(self.ast_ref.nodeMainToken(first)), "this")) return null;
        const bd = self.ast_ref.nodeData(first);
        if (bd.rhs == .none or self.ast_ref.nodeTag(bd.rhs) != .ts_type_annotation) return null;
        return self.resolveTypeNode(self.ast_ref.nodeData(bd.rhs).lhs);
    }

    /// Walk parents from `node` to find the enclosing class instance type.
    /// Returns the structural (object_t) type for the class, or null if not
    /// inside a class method.  Used by memberOnApparentType for `typeRef("this")`.
    fn thisEnclosingClassType(self: *Checker, node: NodeIndex) ?TypeId {
        const parents = self.semantic.parent_indices;
        if (parents.len == 0) return null;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        var p = parents[nidx];
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        while (p != NONE) : (p = parents[p]) {
            const pn: NodeIndex = @enumFromInt(p);
            const tag = self.ast_ref.nodeTag(pn);
            switch (tag) {
                .method_def, .computed_method_def, .getter_def, .setter_def,
                .computed_getter_def, .computed_setter_def, .constructor_def => {
                    var q = parents[p];
                    while (q != NONE) : (q = parents[q]) {
                        const qn: NodeIndex = @enumFromInt(q);
                        const qtag = self.ast_ref.nodeTag(qn);
                        if (qtag == .class_decl or qtag == .class_expr) {
                            const cdata = self.ast_ref.nodeData(qn);
                            if (cdata.lhs == .none) return null;
                            const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
                            if (cd.name == .none) return null;
                            const qname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(cd.name));
                            if (qname.len == 0) return null;
                            return self.resolveDeclaredType(qname);
                        }
                        if (qtag == .class_body) continue;
                    }
                    return null;
                },
                .fn_decl, .async_fn_decl, .generator_fn_decl,
                .async_generator_fn_decl, .fn_expr, .async_fn_expr,
                .generator_fn_expr, .async_generator_fn_expr => return null,
                else => {},
            }
        }
        return null;
    }

    /// Direct AST property lookup for `this.prop` inside a class method.
    /// Used as a fallback when the class type is still being built (the normal
    /// resolveDeclaredType path returns the ID_UNKNOWN sentinel).  Scans the
    /// class body for an annotated instance property with the given name.
    fn thisClassDirectPropLookup(self: *Checker, node: NodeIndex, prop_name: []const u8) ?TypeId {
        const parents = self.semantic.parent_indices;
        if (parents.len == 0) return null;
        const nidx = node.toInt();
        if (nidx >= parents.len) return null;
        var p = parents[nidx];
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var class_decl: NodeIndex = .none;
        outer: while (p != NONE) : (p = parents[p]) {
            const pn: NodeIndex = @enumFromInt(p);
            switch (self.ast_ref.nodeTag(pn)) {
                .method_def, .computed_method_def, .getter_def, .setter_def,
                .computed_getter_def, .computed_setter_def, .constructor_def,
                .property_def => {
                    var q = parents[p];
                    while (q != NONE) : (q = parents[q]) {
                        const qn: NodeIndex = @enumFromInt(q);
                        const qtag = self.ast_ref.nodeTag(qn);
                        if (qtag == .class_decl or qtag == .class_expr) {
                            class_decl = qn;
                            break :outer;
                        }
                        if (qtag == .class_body) continue;
                    }
                    break :outer;
                },
                .fn_decl, .async_fn_decl, .generator_fn_decl,
                .async_generator_fn_decl, .fn_expr, .async_fn_expr,
                .generator_fn_expr, .async_generator_fn_expr => break,
                else => {},
            }
        }
        if (class_decl == .none) return null;
        const cdata_node = self.ast_ref.nodeData(class_decl);
        if (cdata_node.lhs == .none) return null;
        const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata_node.lhs));
        if (cd.body == .none) return null;
        const body_data = self.ast_ref.nodeData(cd.body);
        const slice = self.directRange(body_data.lhs, body_data.rhs) orelse return null;
        for (slice) |raw| {
            const m: NodeIndex = @enumFromInt(raw);
            if (self.ast_ref.nodeTag(m) != .property_def) continue;
            if (self.classMemberIsStatic(m)) continue;
            const mdata = self.ast_ref.nodeData(m);
            if (mdata.lhs == .none or mdata.rhs == .none) continue;
            const ktag = self.ast_ref.nodeTag(mdata.lhs);
            if (ktag != .identifier and ktag != .property_ident) continue;
            const key = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(mdata.lhs));
            if (!std.mem.eql(u8, key, prop_name)) continue;
            const pd = self.ast_ref.extraData(ast.PropertyData, @intFromEnum(mdata.rhs));
            if (pd.type_annotation == .none) return null;
            const ty_node = self.ast_ref.nodeData(pd.type_annotation).lhs;
            return self.resolveTypeNode(ty_node);
        }
        return null;
    }

    /// `super` inside a class member types as the base class — the instance
    /// type in instance members (`super : A`), the constructor type in
    /// static members (`super : typeof A`).  Arrow functions inherit the
    /// enclosing member's `super` binding; other functions break it.
    fn inferSuper(self: *Checker, node: NodeIndex) TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return tymod.ID_ANY;
        // `super(...)` invokes the base constructor → `typeof A`, while
        // `super.x` accesses the base instance → `A`.
        const is_call = blk: {
            const pi = parents[nidx];
            if (pi == @intFromEnum(NodeIndex.none)) break :blk false;
            const par: NodeIndex = @enumFromInt(pi);
            const pt = self.ast_ref.nodeTag(par);
            if (pt != .call_expr and pt != .optional_call_expr) break :blk false;
            break :blk self.ast_ref.nodeData(par).lhs == node;
        };
        var p = parents[nidx];
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        while (p != NONE) : (p = parents[p]) {
            const pn: NodeIndex = @enumFromInt(p);
            switch (self.ast_ref.nodeTag(pn)) {
                .method_def, .computed_method_def, .getter_def, .setter_def,
                .computed_getter_def, .computed_setter_def, .constructor_def,
                .property_def => {
                    const is_static = self.classMemberIsStatic(pn) or is_call;
                    var q = parents[p];
                    while (q != NONE) : (q = parents[q]) {
                        const qn: NodeIndex = @enumFromInt(q);
                        const qtag = self.ast_ref.nodeTag(qn);
                        if (qtag == .class_decl or qtag == .class_expr) {
                            const cdata = self.ast_ref.nodeData(qn);
                            if (cdata.lhs == .none) return tymod.ID_ANY;
                            const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
                            if (cd.super_class == .none) return tymod.ID_ANY;
                            var sc = cd.super_class;
                            while (true) {
                                const sct = self.ast_ref.nodeTag(sc);
                                if (sct == .grouping_expr or sct == .ts_instantiation_expr) {
                                    sc = self.ast_ref.nodeData(sc).lhs;
                                    continue;
                                }
                                break;
                            }
                            if (self.ast_ref.nodeTag(sc) != .identifier) return tymod.ID_ANY;
                            const base = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(sc));
                            if (base.len == 0) return tymod.ID_ANY;
                            if (is_static) {
                                const tn = std.fmt.allocPrint(self.gpa, "typeof {s}", .{base}) catch return tymod.ID_ANY;
                                return self.store.typeRef(tn, &.{}) catch tymod.ID_ANY;
                            }
                            return self.store.typeRef(base, &.{}) catch tymod.ID_ANY;
                        }
                        if (qtag != .class_body) break;
                    }
                    return tymod.ID_ANY;
                },
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                .class_decl, .class_expr => return tymod.ID_ANY,
                else => {},
            }
        }
        return tymod.ID_ANY;
    }

    /// `this` inside a class method/getter/setter/constructor resolves
    /// to the enclosing class's instance type.  Walks parents to find
    /// the nearest method-or-class declaration.  A stand-alone function's
    /// `this` is its `this: T` annotation, else implicit `any` (strict).
    fn inferThis(self: *Checker, node: NodeIndex) TypeId {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return tymod.ID_ANY;
        var p = parents[nidx];
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        while (p != NONE) : (p = parents[p]) {
            const pn: NodeIndex = @enumFromInt(p);
            const tag = self.ast_ref.nodeTag(pn);
            // Reaching another fn_decl/fn_expr/arrow_fn that ISN'T a
            // method definition means we've left the class context.
            // Arrow functions inherit `this`, so we keep walking through
            // arrow_fn but stop at non-arrow function definitions.
            switch (tag) {
                .method_def, .computed_method_def, .getter_def, .setter_def,
                .computed_getter_def, .computed_setter_def, .constructor_def,
                .property_def => {
                    const is_static = self.classMemberIsStatic(@enumFromInt(p));
                    // Walk up to the class_decl / class_expr.
                    var q = parents[p];
                    while (q != NONE) : (q = parents[q]) {
                        const qn: NodeIndex = @enumFromInt(q);
                        const qtag = self.ast_ref.nodeTag(qn);
                        if (qtag == .class_decl or qtag == .class_expr) {
                            if (is_static) {
                                // Static context: `this` is the class constructor → typeof C.
                                const cdata = self.ast_ref.nodeData(qn);
                                if (cdata.lhs != .none) {
                                    const cd = self.ast_ref.extraData(ast.ClassData, @intFromEnum(cdata.lhs));
                                    if (cd.name != .none) {
                                        const cls_name = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(cd.name));
                                        if (cls_name.len > 0) {
                                            const tn = std.fmt.allocPrint(self.gpa, "typeof {s}", .{cls_name}) catch return tymod.ID_ANY;
                                            return self.store.typeRef(tn, &.{}) catch tymod.ID_ANY;
                                        }
                                    }
                                }
                                return tymod.ID_ANY;
                            }
                            return self.store.typeRef("this", &.{}) catch tymod.ID_ANY;
                        }
                        // class_body sits between member and class_decl/expr;
                        // keep walking until we hit the decl/expr.
                        if (qtag == .class_body) continue;
                        // Other intermediate nodes (computed key wrappers?) — keep walking.
                    }
                    return tymod.ID_ANY;
                },
                // Hit a function context that owns its own `this` binding —
                // `this` here doesn't belong to an enclosing class. A `this: T`
                // parameter annotation types it; otherwise it's implicit `any`
                // (strict noImplicitThis), which the no-unsafe-* rules flag.
                .fn_decl, .async_fn_decl, .generator_fn_decl,
                .async_generator_fn_decl, .fn_expr, .async_fn_expr,
                .generator_fn_expr, .async_generator_fn_expr => {
                    if (self.functionThisParamType(pn)) |tp| return tp;
                    return tymod.ID_ANY;
                },
                else => {},
            }
        }
        return tymod.ID_ANY;
    }

    /// Infer the type of a `new.target` expression.
    ///
    /// TypeScript types `new.target` as the enclosing non-arrow function's
    /// own type (a function_t).  Arrow functions are transparent — they
    /// inherit `new.target` from their lexical enclosing non-arrow function.
    /// Inside a constructor the result is approximately `() => any`
    /// (the full `typeof ClassName` requires class-side type building which
    /// we avoid here to keep the change minimal).  The key invariant is
    /// that the result is always a function_t, never bare `any`.
    fn inferNewTarget(self: *Checker, node: NodeIndex) TypeId {
        // Build a reusable `() => any` sentinel for constructor and
        // unknown-context fallbacks.
        const any_fn = self.store.functionType(.{
            .params_start = 0,
            .params_end = 0,
            .return_type = tymod.ID_ANY,
        }) catch return tymod.ID_ANY;

        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return any_fn;
        var p = parents[nidx];
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        while (p != NONE) : (p = parents[p]) {
            const pn: NodeIndex = @enumFromInt(p);
            const tag = self.ast_ref.nodeTag(pn);
            switch (tag) {
                // Arrow functions are transparent for new.target — keep walking.
                .arrow_fn, .async_arrow_fn => {},
                // A no-body constructor_def: tsc returns `typeof ClassName`
                // which requires class-side type building we avoid here.
                // Return ID_ANY (coverage gap) rather than a wrong function type.
                .constructor_def => return tymod.ID_ANY,
                // Regular function declarations and expressions: return the
                // function's own type so `new.target` is at least a function_t.
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr => {
                    return self.functionTypeFromFnDecl(pn);
                },
                // Method / getter / setter in a class body.
                // For a regular method, new.target is `() => any`.
                // For a constructor method (key = "constructor"), tsc returns
                // `typeof ClassName` — leave as ID_ANY to avoid a wrong type.
                .method_def, .computed_method_def => {
                    const md = self.ast_ref.nodeData(pn);
                    if (md.lhs != .none) {
                        const kt = self.ast_ref.nodeTag(md.lhs);
                        if (kt == .identifier or kt == .property_ident) {
                            const kname = self.ast_ref.tokenText(self.ast_ref.nodeMainToken(md.lhs));
                            if (std.mem.eql(u8, kname, "constructor")) return tymod.ID_ANY;
                        }
                    }
                    return any_fn;
                },
                .getter_def, .setter_def,
                .computed_getter_def, .computed_setter_def => return any_fn,
                else => {},
            }
        }
        return any_fn;
    }

    /// Returns the nearest enclosing non-arrow function node, or .none.
    /// Arrow functions are transparent for `arguments` (they inherit from outer scope).
    fn enclosingNonArrowFunction(self: *Checker, node: NodeIndex) NodeIndex {
        const parents = self.semantic.parent_indices;
        const nidx = node.toInt();
        if (nidx >= parents.len) return .none;
        const NONE: u32 = @intFromEnum(NodeIndex.none);
        var p = parents[nidx];
        while (p != NONE) : (p = parents[p]) {
            const pn: NodeIndex = @enumFromInt(p);
            switch (self.ast_ref.nodeTag(pn)) {
                .arrow_fn, .async_arrow_fn => {},
                .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
                .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
                .method_def, .computed_method_def, .getter_def, .setter_def,
                .computed_getter_def, .computed_setter_def, .constructor_def => return pn,
                else => {},
            }
        }
        return .none;
    }

    fn inferAwait(self: *Checker, node: NodeIndex) TypeId {
        // await unwraps Promise<T> → T, recursing through unions (await of
        // `Promise<A> | Promise<B>` → `A | B`) and nested promises — so a
        // conditional like `if (await (p ?? Promise.reject()))` is seen as its
        // awaited value, not a thenable.
        const inner = self.typeOf(self.ast_ref.nodeData(node).lhs);
        return self.resolveAwaited(inner);
    }

    /// True when the class/function declaration `decl_node` has a decorator
    /// named `name` (i.e. `@name` or `@name(...)` appears immediately before
    /// the declaration in the token stream).  Scans backward from the
    /// declaration's main_token through `@`, identifier, `(...)` sequences.
    pub fn hasDecoratorNamed(self: *const Checker, decl_node: NodeIndex, name: []const u8) bool {
        if (decl_node == .none) return false;
        const class_tok = self.ast_ref.nodeMainToken(decl_node);
        if (class_tok == 0) return false;
        const tokens = self.ast_ref.tokens;
        var i: u32 = class_tok;
        // Skip past any leading keywords (abstract, declare, export, async, default)
        // that appear between decorators and the class/function keyword.
        while (i > 0) {
            const prev = i - 1;
            const ttag = tokens.items(.tag)[prev];
            switch (ttag) {
                .kw_abstract, .kw_declare, .kw_export, .kw_async, .kw_default => i = prev,
                else => break,
            }
        }
        // Now scan backwards looking for @name patterns.
        while (i > 0) {
            var j = i - 1;
            // Skip a decorator call's argument list: (...).
            if (j > 0 and tokens.items(.tag)[j] == .r_paren) {
                var depth: u32 = 1;
                j -= 1;
                while (j > 0 and depth > 0) : (j -= 1) {
                    const t2 = tokens.items(.tag)[j];
                    if (t2 == .r_paren) depth += 1;
                    if (t2 == .l_paren) depth -= 1;
                }
            }
            // Skip dotted member chains: .foo.bar
            while (j > 0 and tokens.items(.tag)[j] == .identifier) {
                if (j < 2) break;
                if (tokens.items(.tag)[j - 1] == .dot) {
                    j -= 2;
                } else break;
            }
            // Check for identifier (decorator name).
            if (j == 0 and tokens.items(.tag)[0] != .identifier) break;
            if (tokens.items(.tag)[j] != .identifier) break;
            // Check that the token before the identifier is `@`.
            if (j == 0) break;
            if (tokens.items(.tag)[j - 1] != .at_sign) break;
            const dec_name = self.ast_ref.tokenText(j);
            if (std.mem.eql(u8, dec_name, name)) return true;
            i = j - 1; // move before the `@`
        }
        return false;
    }

    /// Convert a TypeId to a tsc-compatible type string.  Union members are
    /// sorted alphabetically so the output is stable for baseline comparison.
    /// The caller owns the returned slice (allocated from `gpa`).
    pub fn typeToString(self: *Checker, id: TypeId) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        try self.typeToStringInner(id, &buf, 0);
        return buf.toOwnedSlice(self.gpa);
    }

    fn typeToStringInner(self: *Checker, id: TypeId, buf: *std.ArrayList(u8), depth: u8) !void {
        const gpa = self.gpa;
        if (depth > 8) {
            try buf.appendSlice(gpa, "...");
            return;
        }
        const t = self.store.get(id);
        switch (t.kind) {
            .any         => try buf.appendSlice(gpa, "any"),
            .unknown     => try buf.appendSlice(gpa, "unknown"),
            .never       => try buf.appendSlice(gpa, "never"),
            .null_t      => try buf.appendSlice(gpa, "null"),
            .undefined_t => try buf.appendSlice(gpa, "undefined"),
            .void_t      => try buf.appendSlice(gpa, "void"),
            .number, .string => {
                // Opaque (computed-initializer) enum members display E.A.
                if (t.enum_name.len > 0 and t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                } else if (t.enum_name.len > 0 and t.name.len > 0) {
                    try buf.appendSlice(gpa, t.enum_name);
                    try buf.append(gpa, '.');
                    try buf.appendSlice(gpa, t.name);
                } else {
                    try buf.appendSlice(gpa, if (t.kind == .number) "number" else "string");
                }
            },
            .boolean     => try buf.appendSlice(gpa, "boolean"),
            .bigint      => try buf.appendSlice(gpa, "bigint"),
            .symbol      => try buf.appendSlice(gpa, "symbol"),
            .object_keyword => try buf.appendSlice(gpa, "object"),
            .error_t     => try buf.appendSlice(gpa, "error"),
            .type_ref => {
                try buf.appendSlice(gpa, t.name);
                const args = self.store.idsOf(t.list_data);
                if (args.len > 0) {
                    try buf.append(gpa, '<');
                    for (args, 0..) |arg, ai| {
                        if (ai > 0) try buf.appendSlice(gpa, ", ");
                        try self.typeToStringInner(arg, buf, depth + 1);
                    }
                    try buf.append(gpa, '>');
                }
            },
            .type_param  => try buf.appendSlice(gpa, t.name),
            .string_literal => {
                // String enum members render as EnumName.MemberName; a
                // single-member enum's lone member is aliased to the enum name.
                if (t.enum_name.len > 0 and t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                } else if (t.enum_name.len > 0 and t.name.len > 0) {
                    try buf.appendSlice(gpa, t.enum_name);
                    try buf.append(gpa, '.');
                    try buf.appendSlice(gpa, t.name);
                } else {
                try buf.append(gpa, '"');
                const slit = t.literal_value.string;
                var si: usize = 0;
                while (si < slit.len) : (si += 1) {
                    const byte = slit[si];
                    if (byte == 0x00) {
                        // TypeScript renders the null byte as \0, but uses \x00 when
                        // followed by a decimal digit to avoid ambiguity.
                        const next_is_digit = si + 1 < slit.len and slit[si + 1] >= '0' and slit[si + 1] <= '9';
                        if (next_is_digit) {
                            try buf.appendSlice(gpa, "\\x00");
                        } else {
                            try buf.appendSlice(gpa, "\\0");
                        }
                    } else if (byte < 0x20) {
                        // Encode C0 control characters as \uXXXX (uppercase hex, matching tsc)
                        try buf.print(gpa, "\\u{X:0>4}", .{byte});
                    } else if (byte == '"') {
                        try buf.appendSlice(gpa, "\\\"");
                    } else if (byte == '\\') {
                        try buf.appendSlice(gpa, "\\\\");
                    } else {
                        try buf.append(gpa, byte);
                    }
                }
                try buf.append(gpa, '"');
                } // end else (not an enum member)
            },
            .number_literal => {
                // Enum member literals render as EnumName.MemberName (e.g. E.B).
                if (t.enum_name.len > 0 and t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                } else if (t.enum_name.len > 0 and t.name.len > 0) {
                    try buf.appendSlice(gpa, t.enum_name);
                    try buf.append(gpa, '.');
                    try buf.appendSlice(gpa, t.name);
                } else {
                    const n = t.literal_value.number;
                    if (std.math.isPositiveInf(n)) {
                        try buf.appendSlice(gpa, "Infinity");
                    } else if (std.math.isNegativeInf(n)) {
                        try buf.appendSlice(gpa, "-Infinity");
                    } else if (std.math.isNan(n)) {
                        try buf.appendSlice(gpa, "NaN");
                    } else {
                        // Integer-valued literals print without a decimal point — but
                        // only when in i64 range, else @intFromFloat is UB (e.g. 1e300).
                        const i64_min: f64 = -9223372036854775808.0;
                        const i64_max: f64 = 9223372036854775808.0;
                        if (n == @trunc(n) and n >= i64_min and n < i64_max) {
                            try buf.print(gpa, "{d}", .{@as(i64, @intFromFloat(n))});
                        } else {
                            try buf.print(gpa, "{d}", .{n});
                        }
                    }
                }
            },
            .boolean_literal => try buf.appendSlice(gpa, if (t.literal_value.boolean) "true" else "false"),
            .bigint_literal  => try buf.print(gpa, "{s}n", .{t.literal_value.bigint}),
            .array_t => {
                const ids = self.store.idsOf(t.list_data);
                if (ids.len > 0) {
                    const elem = self.store.get(ids[0]);
                    // A union/intersection that renders as its alias name is a
                    // single identifier - no parens (`BigUnion[]`, not `(BigUnion)[]`).
                    const multi_token_compound = (elem.kind == .union_t or elem.kind == .intersection_t) and
                        elem.alias_name.len == 0;
                    const needs_parens = multi_token_compound or
                        elem.kind == .function_t or
                        (elem.kind == .type_ref and std.mem.startsWith(u8, elem.name, "typeof "));
                    if (needs_parens) try buf.appendSlice(gpa, "(");
                    try self.typeToStringInner(ids[0], buf, depth + 1);
                    if (needs_parens) try buf.appendSlice(gpa, ")");
                } else {
                    try buf.appendSlice(gpa, "unknown");
                }
                try buf.appendSlice(gpa, "[]");
            },
            .readonly_array_t => {
                try buf.appendSlice(gpa, "readonly ");
                const ids = self.store.idsOf(t.list_data);
                if (ids.len > 0) {
                    const elem = self.store.get(ids[0]);
                    // A union/intersection that renders as its alias name is a
                    // single identifier - no parens (`BigUnion[]`, not `(BigUnion)[]`).
                    const multi_token_compound = (elem.kind == .union_t or elem.kind == .intersection_t) and
                        elem.alias_name.len == 0;
                    const needs_parens = multi_token_compound or
                        elem.kind == .function_t or
                        (elem.kind == .type_ref and std.mem.startsWith(u8, elem.name, "typeof "));
                    if (needs_parens) try buf.appendSlice(gpa, "(");
                    try self.typeToStringInner(ids[0], buf, depth + 1);
                    if (needs_parens) try buf.appendSlice(gpa, ")");
                } else {
                    try buf.appendSlice(gpa, "unknown");
                }
                try buf.appendSlice(gpa, "[]");
            },
            .tuple_t => {
                if (t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                    return;
                }
                if (t.name.len > 0) try buf.appendSlice(gpa, "readonly ");
                try buf.appendSlice(gpa, "[");
                for (self.store.idsOf(t.list_data), 0..) |m, i| {
                    if (i > 0) try buf.appendSlice(gpa, ", ");
                    const mt = self.store.get(m);
                    if (mt.kind == .rest_t) {
                        try buf.appendSlice(gpa, "...");
                        const inner_ids = self.store.idsOf(mt.list_data);
                        if (inner_ids.len > 0) {
                            try self.typeToStringInner(inner_ids[0], buf, depth + 1);
                        }
                    } else {
                        try self.typeToStringInner(m, buf, depth + 1);
                    }
                }
                try buf.appendSlice(gpa, "]");
            },
            .rest_t => {
                // Shouldn't appear outside tuple context; serialize as `...T`.
                try buf.appendSlice(gpa, "...");
                const inner_ids = self.store.idsOf(t.list_data);
                if (inner_ids.len > 0) {
                    try self.typeToStringInner(inner_ids[0], buf, depth + 1);
                }
            },
            .function_t => {
                // If tagged with a type-alias name, render as the alias (e.g. `type Handler = (...) => void`).
                if (t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                    return;
                }
                const sigs = self.store.signaturesOf(t.signatures);
                if (sigs.len == 0) {
                    try buf.appendSlice(gpa, "() => unknown");
                } else if (sigs.len == 1 and !t.is_overload_set) {
                    const sig = sigs[0];
                    const params = self.store.signatureParamsOf(sig);
                    const names = self.store.signatureParamNamesOf(sig);
                    const opts = self.store.signatureParamOptionalsOf(sig);
                    if (sig.is_construct) try buf.appendSlice(gpa, "new ");
                    if (self.fn_type_params.get(id)) |tp_prefix|
                        try buf.appendSlice(gpa, tp_prefix);
                    try buf.append(gpa, '(');
                    for (params, 0..) |param_ty, pi| {
                        if (pi > 0) try buf.appendSlice(gpa, ", ");
                        const is_rest = sig.rest_param_index != 0xFFFF and pi == sig.rest_param_index;
                        if (is_rest) try buf.appendSlice(gpa, "...");
                        const pname = if (pi < names.len) names[pi] else "";
                        const is_opt = !is_rest and pi < opts.len and opts[pi];
                        if (pname.len > 0) {
                            try buf.appendSlice(gpa, pname);
                            if (is_opt) try buf.append(gpa, '?');
                            try buf.appendSlice(gpa, ": ");
                        }
                        try self.typeToStringInner(param_ty, buf, depth + 1);
                    }
                    try buf.appendSlice(gpa, ") => ");
                    if (sig.predicate_param_index != 0xFFFF and sig.predicate_target != .none) {
                        const pred_name = if (sig.predicate_param_index < names.len) names[sig.predicate_param_index] else "";
                        if (pred_name.len > 0) {
                            if (sig.is_assertion) try buf.appendSlice(gpa, "asserts ");
                            try buf.appendSlice(gpa, pred_name);
                            try buf.appendSlice(gpa, " is ");
                            try self.typeToStringInner(sig.predicate_target, buf, depth + 1);
                        } else {
                            try self.typeToStringInner(sig.return_type, buf, depth + 1);
                        }
                    } else if (sig.is_assertion and sig.predicate_param_index != 0xFFFF) {
                        const pred_name = if (sig.predicate_param_index < names.len) names[sig.predicate_param_index] else "";
                        if (pred_name.len > 0) {
                            try buf.appendSlice(gpa, "asserts ");
                            try buf.appendSlice(gpa, pred_name);
                        } else {
                            try self.typeToStringInner(sig.return_type, buf, depth + 1);
                        }
                    } else {
                        try self.typeToStringInner(sig.return_type, buf, depth + 1);
                    }
                } else {
                    // Multi-signature (overloads) — tsc renders as { (p): T; (p): T; }
                    try buf.appendSlice(gpa, "{ ");
                    for (sigs, 0..) |sig, si| {
                        if (si > 0) try buf.appendSlice(gpa, "; ");
                        const params = self.store.signatureParamsOf(sig);
                        const names = self.store.signatureParamNamesOf(sig);
                        const opts = self.store.signatureParamOptionalsOf(sig);
                        const sig_pool_idx: u32 = t.signatures.start + @as(u32, @intCast(si));
                        if (self.sig_type_params.get(sig_pool_idx)) |tp_prefix| {
                            try buf.appendSlice(gpa, tp_prefix);
                        }
                        try buf.append(gpa, '(');
                        for (params, 0..) |param_ty, pi| {
                            if (pi > 0) try buf.appendSlice(gpa, ", ");
                            const is_rest = sig.rest_param_index != 0xFFFF and pi == sig.rest_param_index;
                            if (is_rest) try buf.appendSlice(gpa, "...");
                            const pname = if (pi < names.len) names[pi] else "";
                            const is_opt = !is_rest and pi < opts.len and opts[pi];
                            if (pname.len > 0) {
                                try buf.appendSlice(gpa, pname);
                                if (is_opt) try buf.append(gpa, '?');
                                try buf.appendSlice(gpa, ": ");
                            }
                            try self.typeToStringInner(param_ty, buf, depth + 1);
                        }
                        try buf.appendSlice(gpa, "): ");
                        try self.typeToStringInner(sig.return_type, buf, depth + 1);
                    }
                    try buf.appendSlice(gpa, "; }");
                }
            },
            .object_t => {
                // If tagged with a type-alias name (e.g. `type A = {...}`), render
                // as the alias name matching tsc, not the structural expansion.
                // Guard against internal sentinels like "__static__".
                if (t.alias_name.len > 0 and !std.mem.eql(u8, t.alias_name, "__static__")) {
                    try buf.appendSlice(gpa, t.alias_name);
                    return;
                }
                const props = self.store.propsOf(t.object_props);
                const call_sigs = self.store.signaturesOf(t.signatures);
                // Count renderable regular properties (skip index-signature sentinels).
                var real_count: usize = 0;
                var idx_sig_count: usize = 0;
                for (props) |p| {
                    if (std.mem.startsWith(u8, p.name, "[]")) {
                        if (p.index_key_name.len > 0) idx_sig_count += 1;
                    } else {
                        real_count += 1;
                    }
                }
                // Single call/construct signature with no props: render as arrow form.
                if (real_count == 0 and call_sigs.len == 1 and idx_sig_count == 0) {
                    const sig = call_sigs[0];
                    const sparams = self.store.signatureParamsOf(sig);
                    const snames = self.store.signatureParamNamesOf(sig);
                    const sopts = self.store.signatureParamOptionalsOf(sig);
                    if (sig.is_construct) try buf.appendSlice(gpa, "new ");
                    if (self.sig_type_params.get(t.signatures.start)) |tp_prefix|
                        try buf.appendSlice(gpa, tp_prefix);
                    try buf.append(gpa, '(');
                    for (sparams, 0..) |sp, si| {
                        if (si > 0) try buf.appendSlice(gpa, ", ");
                        const is_rest = sig.rest_param_index != 0xFFFF and si == sig.rest_param_index;
                        if (is_rest) try buf.appendSlice(gpa, "...");
                        const sn = if (si < snames.len) snames[si] else "";
                        const is_opt = !is_rest and si < sopts.len and sopts[si];
                        if (sn.len > 0) {
                            try buf.appendSlice(gpa, sn);
                            if (is_opt) try buf.append(gpa, '?');
                            try buf.appendSlice(gpa, ": ");
                        }
                        try self.typeToStringInner(sp, buf, depth + 1);
                    }
                    try buf.appendSlice(gpa, ") => ");
                    try self.typeToStringInner(sig.return_type, buf, depth + 1);
                } else if (real_count == 0 and call_sigs.len == 0 and idx_sig_count == 0) {
                    try buf.appendSlice(gpa, "{}");
                } else {
                    try buf.appendSlice(gpa, "{ ");
                    var first = true;
                    // Render call/construct signatures in object form.
                    for (call_sigs, 0..) |sig, csi| {
                        if (!first) try buf.appendSlice(gpa, "; ");
                        first = false;
                        const sparams = self.store.signatureParamsOf(sig);
                        const snames = self.store.signatureParamNamesOf(sig);
                        const sopts = self.store.signatureParamOptionalsOf(sig);
                        if (sig.is_construct) try buf.appendSlice(gpa, "new ");
                        const pool_idx: u32 = t.signatures.start + @as(u32, @intCast(csi));
                        if (self.sig_type_params.get(pool_idx)) |tp_prefix| {
                            try buf.appendSlice(gpa, tp_prefix);
                        }
                        try buf.append(gpa, '(');
                        for (sparams, 0..) |sp, si| {
                            if (si > 0) try buf.appendSlice(gpa, ", ");
                            const is_rest = sig.rest_param_index != 0xFFFF and si == sig.rest_param_index;
                            if (is_rest) try buf.appendSlice(gpa, "...");
                            const sn = if (si < snames.len) snames[si] else "";
                            const is_opt = !is_rest and si < sopts.len and sopts[si];
                            if (sn.len > 0) {
                                try buf.appendSlice(gpa, sn);
                                if (is_opt) try buf.append(gpa, '?');
                                try buf.appendSlice(gpa, ": ");
                            }
                            try self.typeToStringInner(sp, buf, depth + 1);
                        }
                        try buf.appendSlice(gpa, "): ");
                        try self.typeToStringInner(sig.return_type, buf, depth + 1);
                    }
                    // Render index signatures (e.g. `[key: string]: T`).
                    for (props) |p| {
                        if (!std.mem.startsWith(u8, p.name, "[]")) continue;
                        if (p.index_key_name.len == 0) continue; // skip synthetic/backward-compat entries
                        if (!first) try buf.appendSlice(gpa, "; ");
                        first = false;
                        try buf.append(gpa, '[');
                        try buf.appendSlice(gpa, p.index_key_name);
                        try buf.appendSlice(gpa, ": ");
                        if (std.mem.eql(u8, p.name, "[]L")) {
                            try buf.appendSlice(gpa, "Lowercase<string>");
                        } else if (std.mem.eql(u8, p.name, "[]U")) {
                            try buf.appendSlice(gpa, "Uppercase<string>");
                        } else if (p.index_key_is_number) {
                            try buf.appendSlice(gpa, "number");
                        } else {
                            try buf.appendSlice(gpa, "string");
                        }
                        try buf.appendSlice(gpa, "]: ");
                        try self.typeToStringInner(p.type_id, buf, depth + 1);
                    }
                    for (props) |p| {
                        if (std.mem.startsWith(u8, p.name, "[]")) continue;
                        if (!first) try buf.appendSlice(gpa, "; ");
                        first = false;
                        if (p.readonly) try buf.appendSlice(gpa, "readonly ");
                        if (needsPropertyQuoting(p.name)) {
                            try buf.append(gpa, '"');
                            try buf.appendSlice(gpa, p.name);
                            try buf.append(gpa, '"');
                        } else {
                            try buf.appendSlice(gpa, p.name);
                        }
                        const pv = self.store.get(p.type_id);
                        if (p.is_method and pv.kind == .function_t) {
                            // Render method shorthand: name(): T
                            const msigs = self.store.signaturesOf(pv.signatures);
                            if (p.optional) try buf.append(gpa, '?');
                            if (msigs.len == 1) {
                                const msig = msigs[0];
                                const mparams = self.store.signatureParamsOf(msig);
                                const mnames = self.store.signatureParamNamesOf(msig);
                                if (self.fn_type_params.get(p.type_id)) |tp_prefix|
                                    try buf.appendSlice(gpa, tp_prefix);
                                try buf.append(gpa, '(');
                                const mopts = self.store.signatureParamOptionalsOf(msig);
                                for (mparams, 0..) |mp, mi| {
                                    if (mi > 0) try buf.appendSlice(gpa, ", ");
                                    const mis_rest = msig.rest_param_index != 0xFFFF and mi == msig.rest_param_index;
                                    if (mis_rest) try buf.appendSlice(gpa, "...");
                                    const mn = if (mi < mnames.len) mnames[mi] else "";
                                    const mis_opt = !mis_rest and mi < mopts.len and mopts[mi];
                                    if (mn.len > 0) {
                                        try buf.appendSlice(gpa, mn);
                                        if (mis_opt) try buf.append(gpa, '?');
                                        try buf.appendSlice(gpa, ": ");
                                    }
                                    try self.typeToStringInner(mp, buf, depth + 1);
                                }
                                try buf.appendSlice(gpa, "): ");
                                try self.typeToStringInner(msig.return_type, buf, depth + 1);
                            } else {
                                // Multi-sig overloaded method: render each sig separately.
                                // The name + optional '?' for the first sig were already written.
                                for (msigs, 0..) |msig, msi| {
                                    if (msi > 0) {
                                        try buf.appendSlice(gpa, "; ");
                                        if (p.readonly) try buf.appendSlice(gpa, "readonly ");
                                        if (needsPropertyQuoting(p.name)) {
                                            try buf.append(gpa, '"');
                                            try buf.appendSlice(gpa, p.name);
                                            try buf.append(gpa, '"');
                                        } else {
                                            try buf.appendSlice(gpa, p.name);
                                        }
                                    }
                                    const sig_pool_idx_m: u32 = pv.signatures.start + @as(u32, @intCast(msi));
                                    if (self.sig_type_params.get(sig_pool_idx_m)) |tp_prefix|
                                        try buf.appendSlice(gpa, tp_prefix);
                                    try buf.append(gpa, '(');
                                    const mparams = self.store.signatureParamsOf(msig);
                                    const mnames = self.store.signatureParamNamesOf(msig);
                                    const mopts = self.store.signatureParamOptionalsOf(msig);
                                    for (mparams, 0..) |mp, mi| {
                                        if (mi > 0) try buf.appendSlice(gpa, ", ");
                                        const mis_rest = msig.rest_param_index != 0xFFFF and mi == msig.rest_param_index;
                                        if (mis_rest) try buf.appendSlice(gpa, "...");
                                        const mn = if (mi < mnames.len) mnames[mi] else "";
                                        const mis_opt = !mis_rest and mi < mopts.len and mopts[mi];
                                        if (mn.len > 0) {
                                            try buf.appendSlice(gpa, mn);
                                            if (mis_opt) try buf.append(gpa, '?');
                                            try buf.appendSlice(gpa, ": ");
                                        }
                                        try self.typeToStringInner(mp, buf, depth + 1);
                                    }
                                    try buf.appendSlice(gpa, "): ");
                                    try self.typeToStringInner(msig.return_type, buf, depth + 1);
                                }
                            }
                        } else {
                            if (p.optional) try buf.append(gpa, '?');
                            try buf.appendSlice(gpa, ": ");
                            try self.typeToStringInner(p.type_id, buf, depth + 1);
                        }
                    }
                    try buf.appendSlice(gpa, "; }");
                }
            },
            .intersection_t => {
                // If tagged with a type-alias name, serialize as the alias
                // (e.g. `type T = A & B` at use site shows as `T`, not `A & B`).
                if (t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                    return;
                }
                for (self.store.idsOf(t.list_data), 0..) |m, i| {
                    if (i > 0) try buf.appendSlice(gpa, " & ");
                    try self.typeToStringInner(m, buf, depth + 1);
                }
            },
            .union_t => {
                // If tagged with a type-alias name AND the union contains at least
                // one complex member (not a bare primitive/literal), serialize as
                // the alias. TypeScript reports `All` for `type All = A | B` when
                // A/B are object/named types, but expands simple scalar unions like
                // `type MaybeStr = string | undefined` to `string | undefined`.
                // EXCEPTION: when all members are enum literals from the same enum,
                // output the enum name (e.g. `E.A | E.B` → `E`).
                const members_for_enum = self.store.idsOf(t.list_data);
                // Check if all members are enum literals (from one or more enums).
                // If so, collapse to enum name(s): `E.a | E.b | F.c` → `E | F`.
                const all_enum_members = blk: {
                    if (members_for_enum.len == 0) break :blk false;
                    for (members_for_enum) |m| {
                        if (self.store.get(m).enum_name.len == 0) break :blk false;
                    }
                    break :blk true;
                };
                if (all_enum_members) {
                    if (t.alias_name.len > 0) {
                        try buf.appendSlice(gpa, t.alias_name);
                        return;
                    }
                    // Collect unique enum names in encounter order.
                    var enum_names: [16][]const u8 = undefined;
                    var n_enums: usize = 0;
                    for (members_for_enum) |m| {
                        const ename = self.store.get(m).enum_name;
                        const already = for (enum_names[0..n_enums]) |en| {
                            if (std.mem.eql(u8, en, ename)) break true;
                        } else false;
                        if (!already and n_enums < enum_names.len) {
                            enum_names[n_enums] = ename;
                            n_enums += 1;
                        }
                    }
                    // A PARTIAL union of one enum's members stays expanded
                    // (`E.A | E.B`, not `E`) — collapse only full coverage.
                    const collapse = blk: {
                        if (n_enums != 1) break :blk true; // multi-enum: keep legacy collapse
                        const total = self.enumDeclMemberCount(enum_names[0]) orelse break :blk true;
                        break :blk members_for_enum.len >= total;
                    };
                    if (collapse) {
                        for (enum_names[0..n_enums], 0..) |en, i| {
                            if (i > 0) try buf.appendSlice(gpa, " | ");
                            try buf.appendSlice(gpa, en);
                        }
                        return;
                    }
                    // fall through to normal member-by-member rendering
                }
                if (t.alias_name.len > 0) {
                    const members = self.store.idsOf(t.list_data);
                    const has_complex = for (members) |m| {
                        const mk = self.store.get(m).kind;
                        switch (mk) {
                            .type_ref, .object_t, .function_t, .intersection_t,
                            .array_t, .readonly_array_t, .tuple_t, .type_param => break true,
                            else => {},
                        }
                    } else false;
                    if (has_complex) {
                        try buf.appendSlice(gpa, t.alias_name);
                        return;
                    }
                }
                const ids = self.store.idsOf(t.list_data);
                // Output union members in insertion order (matches tsc's declaration order).
                // Function types in a union need parens to distinguish `(() => T) | U`
                // from `() => T | U` (which reads as `() => (T | U)`).
                for (ids, 0..) |m, i| {
                    if (i > 0) try buf.appendSlice(gpa, " | ");
                    const mt = self.store.get(m);
                    const needs_parens = mt.kind == .function_t and !mt.is_overload_set;
                    if (needs_parens) try buf.appendSlice(gpa, "(");
                    try self.typeToStringInner(m, buf, depth + 1);
                    if (needs_parens) try buf.appendSlice(gpa, ")");
                }
            },
        }
    }
};

/// Returns true when a property key must be quoted in type display output.
/// Valid JS identifiers and non-negative integer literals are unquoted; anything
/// else (hyphens, dots, spaces, leading digits, etc.) needs double-quotes.
fn needsPropertyQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    // Non-negative numeric literal (integer or decimal float): unquoted by tsc.
    // Matches: digits, or digits.digits
    const is_numeric = blk: {
        var dot_seen = false;
        for (name) |c| {
            if (c == '.' and !dot_seen) { dot_seen = true; continue; }
            if (c < '0' or c > '9') break :blk false;
        }
        break :blk true;
    };
    if (is_numeric) return false;
    // Valid identifier: [a-zA-Z_$][a-zA-Z0-9_$]*
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != '$') return true;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return true;
    }
    return false;
}

/// TypeScript canonical TypeFlags priority for union member ordering in inferred
/// array element unions. Matches TS's output: string < number < bigint < boolean
/// < symbol < undefined < null < void < never < any < other.
fn typePriorityForSort(store: *const tymod.TypeStore, id: tymod.TypeId) u8 {
    const t = store.get(id);
    return switch (t.kind) {
        .string, .string_literal => 0,
        .number, .number_literal => 1,
        .bigint, .bigint_literal => 2,
        .boolean, .boolean_literal => 3,
        .symbol => 4,
        .undefined_t => 5,
        .null_t => 6,
        .void_t => 7,
        .never => 8,
        else => 10,
    };
}

fn sortUnionByTypePriority(store: *const tymod.TypeStore, members: []tymod.TypeId) void {
    if (members.len <= 1) return;
    // Insertion sort (members are few, typically 2–4).
    var i: usize = 1;
    while (i < members.len) : (i += 1) {
        const key = members[i];
        const kp = typePriorityForSort(store, key);
        var j: usize = i;
        while (j > 0 and typePriorityForSort(store, members[j - 1]) > kp) : (j -= 1) {
            members[j] = members[j - 1];
        }
        members[j] = key;
    }
}

fn firstNodeOfTag(ast_result: *const Ast, tag: ast.Node.Tag) ?NodeIndex {
    const total: u32 = @intCast(ast_result.nodes.len);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const ni: NodeIndex = @enumFromInt(i);
        if (ast_result.nodeTag(ni) == tag) return ni;
    }
    return null;
}

test "Checker: number literal type" {
    const allocator = std.testing.allocator;
    var lex_result = try parser.Lexer.tokenize(allocator, "42;");
    defer lex_result.deinit(allocator);
    var tokens = lex_result.tokens;
    var ast_result = try parser.Parser.parse(allocator, "42;", tokens.slice());
    defer ast_result.deinit(allocator);
    var sem = try parser.semantic.SemanticAnalyzer.analyze(allocator, &ast_result);
    defer sem.deinit(allocator);

    var checker = try Checker.init(allocator, &ast_result, &sem, .{});
    defer checker.deinit();

    const expr = firstNodeOfTag(&ast_result, .number_literal) orelse return error.NoLiteral;
    // A bare number literal `42` gives a number_literal type (not the widened
    // number type), since the checker preserves literal types for inference.
    try std.testing.expect(checker.store.get(checker.typeOf(expr)).kind == .number_literal);
    try std.testing.expect(!checker.typeIsAny(expr));
}

test "Checker: identifier bound to number annotation" {
    const allocator = std.testing.allocator;
    const src = "const x: number = 1; x;";
    var lex_result = try parser.Lexer.tokenize(allocator, src);
    defer lex_result.deinit(allocator);
    var tokens = lex_result.tokens;
    var ast_result = try parser.Parser.parseWithLanguage(allocator, src, tokens.slice(), .ts, true);
    defer ast_result.deinit(allocator);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &ast_result, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(allocator);

    var checker = try Checker.init(allocator, &ast_result, &sem, .{});
    defer checker.deinit();

    // Find the LAST identifier (the `x` reference) — the binding `x` is also an identifier.
    const total: u32 = @intCast(ast_result.nodes.len);
    var last_ident: ?NodeIndex = null;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const ni: NodeIndex = @enumFromInt(i);
        if (ast_result.nodeTag(ni) == .identifier) last_ident = ni;
    }
    const ident = last_ident orelse return error.NoIdent;
    const ty = checker.typeOf(ident);
    try std.testing.expect(ty.eq(tymod.ID_NUMBER));
}

test "Checker: array of any flagged via containsAny" {
    const allocator = std.testing.allocator;
    const src = "const arr: any[] = []; arr;";
    var lex_result = try parser.Lexer.tokenize(allocator, src);
    defer lex_result.deinit(allocator);
    var tokens = lex_result.tokens;
    var ast_result = try parser.Parser.parseWithLanguage(allocator, src, tokens.slice(), .ts, true);
    defer ast_result.deinit(allocator);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &ast_result, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(allocator);

    var checker = try Checker.init(allocator, &ast_result, &sem, .{});
    defer checker.deinit();

    const total: u32 = @intCast(ast_result.nodes.len);
    var last_ident: ?NodeIndex = null;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const ni: NodeIndex = @enumFromInt(i);
        if (ast_result.nodeTag(ni) == .identifier) last_ident = ni;
    }
    const ident = last_ident orelse return error.NoIdent;
    try std.testing.expect(checker.typeContainsAny(ident));
    try std.testing.expect(!checker.typeIsAny(ident));
}
