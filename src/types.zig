// Type representation for the Ez TS type checker.
//
// Design constraints:
//   * Types live in a TypeStore arena (no individual frees).
//   * TypeId is a u32 index; .none is the sentinel for "not yet computed".
//   * Singletons for the common scalar types live at fixed slots [0..N) so
//     hot-paths can compare TypeIds directly without a flag dispatch.
//   * Composite types (union, intersection, object, function, array, tuple,
//     reference) carry payload slices stored in side-arrays so the base
//     struct stays small and uniform.

const std = @import("std");

pub const TypeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn toInt(self: TypeId) u32 {
        return @intFromEnum(self);
    }
    pub fn fromInt(i: u32) TypeId {
        return @enumFromInt(i);
    }
    pub fn eq(a: TypeId, b: TypeId) bool {
        return @intFromEnum(a) == @intFromEnum(b);
    }
};

pub const TypeKind = enum(u8) {
    // ── scalars (every instance points at the singleton slot) ──
    any,
    unknown,
    never,
    null_t,
    undefined_t,
    void_t,
    number,
    string,
    boolean,
    bigint,
    symbol,
    object_keyword, // the bare `object` keyword (non-primitive)
    /// TS "intrinsic error type" — used when a type reference doesn't
    /// resolve to any declared name (`let v: NotKnown`).  Rules fire
    /// `error*` messageIds on these.
    error_t,

    // ── literals ───────────────────────────────────────────
    string_literal,
    number_literal,
    bigint_literal,
    boolean_literal,

    // ── composite ──────────────────────────────────────────
    union_t,
    intersection_t,
    /// Anonymous object type — `{ a: number; b: string }`.  Properties live
    /// in `object_props` at [extra_start .. extra_end).
    object_t,
    /// Function/method/constructor — signatures in `signatures` at
    /// [extra_start .. extra_end).
    function_t,
    /// Array<T> / T[].  extra_start = element TypeId (single slot).
    array_t,
    /// readonly T[] / ReadonlyArray<T>.  extra_start = element TypeId.
    readonly_array_t,
    /// [A, B, C].  Element TypeIds at [extra_start .. extra_end).
    tuple_t,
    /// Rest element inside a tuple type annotation: `...T[]`.
    /// list_data.start = single slot holding the wrapped array TypeId.
    rest_t,
    /// Named reference: Foo, Foo<T>, etc.  `name` holds the textual name,
    /// type args at [extra_start .. extra_end).  Used pre-resolution and
    /// for type-parameter references that we can't resolve fully.
    type_ref,
    /// Type parameter binding (T inside `function<T>(...)`).
    type_param,
};

/// Side-array of TypeIds — used by union/intersection/tuple/function args.
pub const TypeIdList = struct {
    start: u32,
    end: u32,

    pub const empty: TypeIdList = .{ .start = 0, .end = 0 };

    pub fn len(self: TypeIdList) u32 {
        return self.end - self.start;
    }
};

pub const ObjectProp = struct {
    name: []const u8,
    type_id: TypeId,
    optional: bool = false,
    readonly: bool = false,
    /// True when the property was declared via `method() {}` syntax
    /// (class method_def or object-literal method) — distinguishes
    /// `this`-binding methods from arrow-property fields.  Used by
    /// `unbound-method` to detect potential this-loss when methods are
    /// passed around.
    is_method: bool = false,
    /// True when the property is a class field whose initializer is a
    /// `function() {}` expression — distinguishes the two messageIds in
    /// `@typescript-eslint/unbound-method`: fn-property → "unbound",
    /// method_def → "unboundWithoutThisAnnotation".
    is_fn_property: bool = false,
    /// True when the member carries the `static` modifier (lives on the class
    /// constructor / static side).  Lets `unbound-method`'s `ignoreStatic`
    /// option see the modifier via the facade's synthesized declaration.
    is_static: bool = false,
    /// For index signature props (name == "[]" / "[]L" / "[]U"): the key
    /// parameter name from the declaration (e.g. "key" in `[key: string]`).
    /// Empty string for synthetic/backward-compat "[]" entries — those are
    /// skipped during type rendering so only the declared form is displayed.
    index_key_name: []const u8 = "",
    /// True when the index signature key type is `number` (vs string/symbol).
    index_key_is_number: bool = false,
    /// True when this property's key came from a SINGLE-quoted string literal
    /// in source (`{ 'a-b': 1 }`). tsc preserves the source quote character when
    /// rendering a quoted key, so the renderer emits `'…'` instead of `"…"`.
    /// Only meaningful when the key actually needs quoting.
    key_single_quoted: bool = false,
};

pub const Signature = struct {
    params_start: u32, // into signature_params (TypeId slice)
    params_end: u32,
    return_type: TypeId,
    is_async: bool = false,
    is_generator: bool = false,
    /// True for a construct signature (`new (): T`) — distinguishes
    /// getConstructSignatures from getCallSignatures in the type-aware facade.
    is_construct: bool = false,
    /// For `name is X` type-predicate return types: the zero-based
    /// parameter index that's being narrowed, or 0xFFFF when this
    /// signature isn't a type guard.
    predicate_param_index: u16 = 0xFFFF,
    /// Target type for the predicate (`X` in `name is X`).
    /// Meaningful only when predicate_param_index != 0xFFFF.
    predicate_target: TypeId = .none,
    /// True when the predicate is an assertion (`asserts x` /
    /// `asserts x is X`).  Callers (rules like
    /// strict-boolean-expressions) treat the argument as being in a
    /// boolean / value-testing context.
    is_assertion: bool = false,
    /// Zero-based index of the rest parameter (`...args: T[]`), or 0xFFFF when
    /// the signature has none.  Lets the type-aware facade tell
    /// no-unsafe-argument which trailing param consumes the spread.
    rest_param_index: u16 = 0xFFFF,
};

pub const Type = struct {
    kind: TypeKind,
    /// Tagged extra:
    ///   string_literal/number_literal/bigint_literal/boolean_literal → literal_value
    ///   union/intersection/tuple/function → list_data
    ///   object_t → object_props list
    ///   array_t/readonly_array_t → list_data.start = element TypeId
    ///   type_ref/type_param → name + type_args
    literal_value: LiteralValue = .{ .none = {} },
    list_data: TypeIdList = .empty,
    object_props: ObjectPropList = ObjectPropList.empty,
    signatures: SignatureList = SignatureList.empty,
    name: []const u8 = "",
    /// Type-alias name this type was resolved from (`type Foo = …` → "Foo"),
    /// independent of the structural `name`. Surfaced to the facade as
    /// ts.Type.aliasSymbol. Part of interning identity (see hash/eql) so an
    /// alias-tagged type stays distinct from its bare structural form.
    alias_name: []const u8 = "",
    /// When non-empty, this literal is an enum *member* of the named enum
    /// (`Fruit.Apple` → enum_name = "Fruit"). Surfaced to the facade so it
    /// can OR-in ts.TypeFlags.EnumLiteral and synthesize an EnumMember symbol
    /// for no-unsafe-enum-comparison. Part of interning identity so an enum
    /// member's `0` stays distinct from a plain literal `0`.
    enum_name: []const u8 = "",
    /// True for function_t types created from overload declaration sets.
    /// Forces object-form rendering `{ (x): T; }` even for single signatures,
    /// matching tsc's output for `function f(x: T): U; function f(x: any) {}`.
    /// Part of interning identity so overload types stay distinct from
    /// structurally-identical regular function types.
    is_overload_set: bool = false,
};

pub const LiteralValue = union(enum) {
    none: void,
    string: []const u8,
    number: f64,
    bigint: []const u8,
    boolean: bool,
};

pub const ObjectPropList = struct {
    start: u32,
    end: u32,
    pub const empty: ObjectPropList = .{ .start = 0, .end = 0 };
    pub fn len(self: ObjectPropList) u32 {
        return self.end - self.start;
    }
};

pub const SignatureList = struct {
    start: u32,
    end: u32,
    pub const empty: SignatureList = .{ .start = 0, .end = 0 };
    pub fn len(self: SignatureList) u32 {
        return self.end - self.start;
    }
};

// ── Singleton slots (must match the order in TypeStore.init) ──
pub const ID_ANY: TypeId = @enumFromInt(0);
pub const ID_UNKNOWN: TypeId = @enumFromInt(1);
pub const ID_NEVER: TypeId = @enumFromInt(2);
pub const ID_NULL: TypeId = @enumFromInt(3);
pub const ID_UNDEFINED: TypeId = @enumFromInt(4);
pub const ID_VOID: TypeId = @enumFromInt(5);
pub const ID_NUMBER: TypeId = @enumFromInt(6);
pub const ID_STRING: TypeId = @enumFromInt(7);
pub const ID_BOOLEAN: TypeId = @enumFromInt(8);
pub const ID_BIGINT: TypeId = @enumFromInt(9);
pub const ID_SYMBOL: TypeId = @enumFromInt(10);
pub const ID_OBJECT_KW: TypeId = @enumFromInt(11);
/// "error type" — TS's representation of an unresolved or
/// uncomputable type (e.g. `let v: NotKnown` where `NotKnown` isn't
/// declared anywhere).  TSe's rules fire with `error*` messageIds
/// (`errorMemberExpression`, `errorComputedMemberAccess`, `errorCall`,
/// etc.) on these types in addition to firing on `any`.
pub const ID_ERROR: TypeId = @enumFromInt(12);

pub const SINGLETON_COUNT: u32 = 13;

/// Map an Ez `TypeKind` to the TypeScript `ts.TypeFlags` bitmask value the
/// type-aware lint rules classify on (via `ts-api-utils` `isTypeFlagSet`).
/// This is the core of the JS `ts.Type` facade — the facade reads this flag
/// and the structural accessors instead of running tsc.  Values are the
/// stable `ts.TypeFlags` constants.
pub fn tsTypeFlags(kind: TypeKind) u32 {
    // NOTE: these are the bundled `typescript` package's actual ts.TypeFlags
    // values (verified at runtime) — NOT the historical/standard layout. The JS
    // rules compare `type.flags & ts.TypeFlags.X`, so these MUST match what
    // `require("typescript")` exposes or every flag check except Any/Unknown
    // silently fails. (Facade-only; native rules read TypeKind, not these.)
    return switch (kind) {
        .any => 1, // Any
        .unknown => 2, // Unknown
        .undefined_t => 4, // Undefined
        .null_t => 8, // Null
        .void_t => 16, // Void
        .string => 32, // String
        .number => 64, // Number
        .bigint => 128, // BigInt
        .boolean => 256, // Boolean
        .symbol => 512, // ESSymbol
        .string_literal => 1024, // StringLiteral
        .number_literal => 2048, // NumberLiteral
        .bigint_literal => 4096, // BigIntLiteral
        .boolean_literal => 8192, // BooleanLiteral
        .object_keyword => 131072, // NonPrimitive ("object" keyword)
        .never => 262144, // Never
        .type_param => 524288, // TypeParameter
        // Object-ish kinds all carry the Object flag (Array/tuple/function are
        // object types; type_ref resolves to a named object/class).
        .object_t, .function_t, .array_t, .readonly_array_t, .tuple_t, .type_ref => 1048576, // Object
        .union_t => 134217728, // Union
        .intersection_t => 268435456, // Intersection
        // TS's intrinsic error type behaves like `any` for rule purposes.
        .error_t => 1, // Any
    };
}

fn literalEql(a: LiteralValue, b: LiteralValue) bool {
    return switch (a) {
        .none => b == .none,
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .number => |n| b == .number and n == b.number,
        .bigint => |s| b == .bigint and std.mem.eql(u8, s, b.bigint),
        .boolean => |x| b == .boolean and x == b.boolean,
    };
}

/// Structural hash/eq context for type interning.  Two `Type`s are equal when
/// their kind, literal value, name, and the *contents* behind their pool
/// ranges (list_data / object_props / signatures) match — pool offsets differ
/// between independently-built but structurally-identical types, so we compare
/// dereferenced content, not the raw `{start,end}` ranges.  Children are
/// already-interned canonical TypeIds, so child comparison is by value.
pub const InternContext = struct {
    store: *const TypeStore,

    pub fn hash(self: InternContext, id: TypeId) u64 {
        const t = &self.store.types.items[id.toInt()];
        var h = std.hash.Wyhash.init(@intFromEnum(t.kind));
        switch (t.literal_value) {
            .none => {},
            .string => |s| h.update(s),
            .number => |n| h.update(std.mem.asBytes(&n)),
            .bigint => |s| h.update(s),
            .boolean => |b| {
                const x: u8 = @intFromBool(b);
                h.update(std.mem.asBytes(&x));
            },
        }
        h.update(t.name);
        h.update(t.alias_name);
        h.update(t.enum_name);
        const ovl: u8 = @intFromBool(t.is_overload_set);
        h.update(std.mem.asBytes(&ovl));
        for (self.store.idsOf(t.list_data)) |c| {
            const v = c.toInt();
            h.update(std.mem.asBytes(&v));
        }
        for (self.store.propsOf(t.object_props)) |p| {
            h.update(p.name);
            const v = p.type_id.toInt();
            h.update(std.mem.asBytes(&v));
            const flags = [_]u8{
                @intFromBool(p.optional), @intFromBool(p.readonly),
                @intFromBool(p.is_method), @intFromBool(p.is_fn_property),
                @intFromBool(p.is_static),
                @intFromBool(p.index_key_is_number),
                @intFromBool(p.key_single_quoted),
            };
            h.update(&flags);
            h.update(p.index_key_name);
        }
        for (self.store.signaturesOf(t.signatures)) |s| {
            for (self.store.signatureParamsOf(s)) |pp| {
                const v = pp.toInt();
                h.update(std.mem.asBytes(&v));
            }
            for (self.store.signatureParamOptionalsOf(s)) |opt| {
                const v: u8 = @intFromBool(opt);
                h.update(std.mem.asBytes(&v));
            }
            const rv = s.return_type.toInt();
            h.update(std.mem.asBytes(&rv));
            const flags = [_]u8{
                @intFromBool(s.is_async), @intFromBool(s.is_generator), @intFromBool(s.is_assertion),
                @intFromBool(s.is_construct),
            };
            h.update(&flags);
            h.update(std.mem.asBytes(&s.predicate_param_index));
            const pt = s.predicate_target.toInt();
            h.update(std.mem.asBytes(&pt));
        }
        return h.final();
    }

    pub fn eql(self: InternContext, a: TypeId, b: TypeId) bool {
        if (a.eq(b)) return true;
        const ta = &self.store.types.items[a.toInt()];
        const tb = &self.store.types.items[b.toInt()];
        if (ta.kind != tb.kind) return false;
        if (!literalEql(ta.literal_value, tb.literal_value)) return false;
        if (!std.mem.eql(u8, ta.name, tb.name)) return false;
        if (!std.mem.eql(u8, ta.alias_name, tb.alias_name)) return false;
        if (!std.mem.eql(u8, ta.enum_name, tb.enum_name)) return false;
        if (ta.is_overload_set != tb.is_overload_set) return false;
        const la = self.store.idsOf(ta.list_data);
        const lb = self.store.idsOf(tb.list_data);
        if (la.len != lb.len) return false;
        for (la, lb) |x, y| if (!x.eq(y)) return false;
        const pa = self.store.propsOf(ta.object_props);
        const pb = self.store.propsOf(tb.object_props);
        if (pa.len != pb.len) return false;
        for (pa, pb) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name)) return false;
            if (!x.type_id.eq(y.type_id)) return false;
            if (x.optional != y.optional or x.readonly != y.readonly or
                x.is_method != y.is_method or x.is_fn_property != y.is_fn_property or
                x.is_static != y.is_static) return false;
            if (!std.mem.eql(u8, x.index_key_name, y.index_key_name)) return false;
            if (x.index_key_is_number != y.index_key_is_number) return false;
            if (x.key_single_quoted != y.key_single_quoted) return false;
        }
        const sa = self.store.signaturesOf(ta.signatures);
        const sb = self.store.signaturesOf(tb.signatures);
        if (sa.len != sb.len) return false;
        for (sa, sb) |x, y| {
            if (!x.return_type.eq(y.return_type)) return false;
            if (x.is_async != y.is_async or x.is_generator != y.is_generator or
                x.is_assertion != y.is_assertion or x.is_construct != y.is_construct) return false;
            if (x.rest_param_index != y.rest_param_index) return false;
            if (x.predicate_param_index != y.predicate_param_index) return false;
            if (!x.predicate_target.eq(y.predicate_target)) return false;
            const xpa = self.store.signatureParamsOf(x);
            const ypa = self.store.signatureParamsOf(y);
            if (xpa.len != ypa.len) return false;
            for (xpa, ypa) |m, nn| if (!m.eq(nn)) return false;
            const xoa = self.store.signatureParamOptionalsOf(x);
            const yoa = self.store.signatureParamOptionalsOf(y);
            if (xoa.len != yoa.len) return false;
            for (xoa, yoa) |m, nn| if (m != nn) return false;
        }
        return true;
    }
};

pub const TypeStore = struct {
    gpa: std.mem.Allocator,
    types: std.ArrayList(Type) = .empty,
    /// Structural-interning index: dedups identical types so independently-
    /// built-but-equal types share one slot.  Without it, generic/mapped-type
    /// expansion produced hundreds of thousands of duplicate types.
    intern: std.HashMapUnmanaged(TypeId, void, InternContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Backing storage for TypeIdList payloads (union/intersection/tuple).
    type_id_pool: std.ArrayList(TypeId) = .empty,
    /// Backing storage for object_props.
    object_prop_pool: std.ArrayList(ObjectProp) = .empty,
    /// Backing storage for signature_params (TypeIds packed).
    signature_pool: std.ArrayList(Signature) = .empty,
    signature_param_pool: std.ArrayList(TypeId) = .empty,
    /// Parallel to signature_param_pool: source-text name for each param slot.
    /// Slices point into the AST source buffer (no allocation needed).
    /// Indexed by the same params_start..params_end range as signature_param_pool.
    signature_param_name_pool: std.ArrayList([]const u8) = .empty,
    /// Parallel to signature_param_pool: whether each param is optional (has `?`
    /// or a default value).  Indexed by the same params_start..params_end range.
    signature_param_optional_pool: std.ArrayList(bool) = .empty,

    /// "Committed" pool lengths — the prefix referenced by KEPT (interned)
    /// types. The dedup reclaim in `add` may only give back tail ranges that lie
    /// entirely beyond these watermarks; a range that starts before its
    /// watermark is shared with a kept type (e.g. tagAliasName copies a Type's
    /// struct, sharing its range fields) and truncating it would corrupt that
    /// kept type. Updated after every kept add.
    committed_ids: u32 = 0,
    committed_props: u32 = 0,
    committed_sigs: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) !TypeStore {
        var self: TypeStore = .{ .gpa = gpa };
        try self.types.ensureTotalCapacity(gpa, SINGLETON_COUNT);
        // Order MUST match the ID_* constants above.
        try self.types.append(gpa, .{ .kind = .any });
        try self.types.append(gpa, .{ .kind = .unknown });
        try self.types.append(gpa, .{ .kind = .never });
        try self.types.append(gpa, .{ .kind = .null_t });
        try self.types.append(gpa, .{ .kind = .undefined_t });
        try self.types.append(gpa, .{ .kind = .void_t });
        try self.types.append(gpa, .{ .kind = .number });
        try self.types.append(gpa, .{ .kind = .string });
        try self.types.append(gpa, .{ .kind = .boolean });
        try self.types.append(gpa, .{ .kind = .bigint });
        try self.types.append(gpa, .{ .kind = .symbol });
        try self.types.append(gpa, .{ .kind = .object_keyword });
        try self.types.append(gpa, .{ .kind = .error_t });
        // Register singletons so a stray `add(.{ .kind = .number })` etc.
        // dedups to the canonical ID_* slot rather than creating a twin.
        var i: u32 = 0;
        while (i < SINGLETON_COUNT) : (i += 1) {
            _ = try self.intern.getOrPutContext(gpa, .fromInt(i), .{ .store = &self });
        }
        return self;
    }

    pub fn deinit(self: *TypeStore) void {
        self.types.deinit(self.gpa);
        self.intern.deinit(self.gpa);
        self.type_id_pool.deinit(self.gpa);
        self.object_prop_pool.deinit(self.gpa);
        self.signature_pool.deinit(self.gpa);
        self.signature_param_pool.deinit(self.gpa);
        self.signature_param_name_pool.deinit(self.gpa);
        self.signature_param_optional_pool.deinit(self.gpa);
    }

    pub inline fn get(self: *const TypeStore, id: TypeId) *const Type {
        const i = id.toInt();
        if (i >= self.types.items.len) return &self.types.items[0]; // return 'any' on corrupt id
        return &self.types.items[i];
    }

    pub fn add(self: *TypeStore, ty: Type) !TypeId {
        // Tentatively append so the intern context can hash/compare it, then
        // dedup.  On a hit, discard the tentative type and reclaim the pool
        // tails it just appended (append-then-add ⇒ those ranges are the tail).
        const id: TypeId = .fromInt(@intCast(self.types.items.len));
        try self.types.append(self.gpa, ty);
        const gop = try self.intern.getOrPutContext(self.gpa, id, .{ .store = self });
        if (gop.found_existing) {
            self.types.items.len -= 1;
            // If the kept type is a function with unnamed params, enrich it with
            // names from the new type before reclaiming the new type's sig ranges.
            // This way `(number) => void` from lib defs gains the name `v` when
            // user code defines `function foo(v: number): void`.
            if (ty.kind == .function_t) {
                const kept_id = gop.key_ptr.*;
                const kept_t = &self.types.items[kept_id.toInt()];
                const kept_sigs = self.signaturesOf(kept_t.signatures);
                const new_sigs = self.signaturesOf(ty.signatures);
                if (kept_sigs.len == new_sigs.len) {
                    for (kept_sigs, new_sigs) |ks, ns| {
                        const param_count = ks.params_end - ks.params_start;
                        if (param_count == ns.params_end - ns.params_start and
                            ks.params_end <= self.signature_param_name_pool.items.len and
                            ns.params_end <= self.signature_param_name_pool.items.len)
                        {
                            for (0..param_count) |pi| {
                                const ki = ks.params_start + pi;
                                const ni = ns.params_start + pi;
                                if (self.signature_param_name_pool.items[ki].len == 0 and
                                    self.signature_param_name_pool.items[ni].len > 0)
                                {
                                    self.signature_param_name_pool.items[ki] =
                                        self.signature_param_name_pool.items[ni];
                                }
                            }
                        }
                    }
                }
            }
            // Reclaim ONLY genuinely-fresh tail ranges: the range must be the pool
            // tail AND start at/after the committed watermark. A range starting
            // before its watermark is shared with a kept type (tagAliasName copies
            // a Type's range fields without re-appending) — truncating it would
            // corrupt that kept type's data.
            if (ty.list_data.end != 0 and ty.list_data.end == self.type_id_pool.items.len and ty.list_data.start >= self.committed_ids)
                self.type_id_pool.items.len = ty.list_data.start;
            if (ty.object_props.end != 0 and ty.object_props.end == self.object_prop_pool.items.len and ty.object_props.start >= self.committed_props)
                self.object_prop_pool.items.len = ty.object_props.start;
            if (ty.signatures.end != 0 and ty.signatures.end == self.signature_pool.items.len and ty.signatures.start >= self.committed_sigs)
                self.signature_pool.items.len = ty.signatures.start;
            return gop.key_ptr.*;
        }
        // Kept: this type's pool data is now referenced — advance the watermarks.
        self.committed_ids = @intCast(self.type_id_pool.items.len);
        self.committed_props = @intCast(self.object_prop_pool.items.len);
        self.committed_sigs = @intCast(self.signature_pool.items.len);
        return id;
    }

    /// Append the given TypeIds to the pool and return a list pointing at them.
    pub fn appendTypeIds(self: *TypeStore, ids: []const TypeId) !TypeIdList {
        const start: u32 = @intCast(self.type_id_pool.items.len);
        try self.type_id_pool.appendSlice(self.gpa, ids);
        const end: u32 = @intCast(self.type_id_pool.items.len);
        return .{ .start = start, .end = end };
    }

    pub fn idsOf(self: *const TypeStore, list: TypeIdList) []const TypeId {
        return self.type_id_pool.items[list.start..list.end];
    }

    pub fn appendObjectProps(self: *TypeStore, props: []const ObjectProp) !ObjectPropList {
        const start: u32 = @intCast(self.object_prop_pool.items.len);
        try self.object_prop_pool.appendSlice(self.gpa, props);
        const end: u32 = @intCast(self.object_prop_pool.items.len);
        return .{ .start = start, .end = end };
    }

    pub fn propsOf(self: *const TypeStore, list: ObjectPropList) []const ObjectProp {
        return self.object_prop_pool.items[list.start..list.end];
    }

    pub const ParamRange = struct { start: u32, end: u32 };

    /// Append a slice of signature param TypeIds (and optional parallel names and
    /// optional-flags) and return a range.  `names` and `optionals` must each be
    /// the same length as `params` or empty; empty slices produce placeholders.
    pub fn appendSignatureParams(
        self: *TypeStore,
        params: []const TypeId,
        names: []const []const u8,
    ) !ParamRange {
        return self.appendSignatureParamsFull(params, names, &.{});
    }

    pub fn appendSignatureParamsFull(
        self: *TypeStore,
        params: []const TypeId,
        names: []const []const u8,
        optionals: []const bool,
    ) !ParamRange {
        const start: u32 = @intCast(self.signature_param_pool.items.len);
        try self.signature_param_pool.appendSlice(self.gpa, params);
        const end: u32 = @intCast(self.signature_param_pool.items.len);
        if (names.len == params.len) {
            try self.signature_param_name_pool.appendSlice(self.gpa, names);
        } else {
            for (params) |_| try self.signature_param_name_pool.append(self.gpa, "");
        }
        if (optionals.len == params.len) {
            try self.signature_param_optional_pool.appendSlice(self.gpa, optionals);
        } else {
            for (params) |_| try self.signature_param_optional_pool.append(self.gpa, false);
        }
        return .{ .start = start, .end = end };
    }

    pub fn signatureParamsOf(self: *const TypeStore, sig: Signature) []const TypeId {
        return self.signature_param_pool.items[sig.params_start..sig.params_end];
    }

    pub fn signatureParamNamesOf(self: *const TypeStore, sig: Signature) []const []const u8 {
        const end = sig.params_end;
        if (end > self.signature_param_name_pool.items.len) return &.{};
        return self.signature_param_name_pool.items[sig.params_start..end];
    }

    pub fn signatureParamOptionalsOf(self: *const TypeStore, sig: Signature) []const bool {
        const end = sig.params_end;
        if (end > self.signature_param_optional_pool.items.len) return &.{};
        return self.signature_param_optional_pool.items[sig.params_start..end];
    }

    pub fn appendSignatures(self: *TypeStore, sigs: []const Signature) !SignatureList {
        const start: u32 = @intCast(self.signature_pool.items.len);
        try self.signature_pool.appendSlice(self.gpa, sigs);
        const end: u32 = @intCast(self.signature_pool.items.len);
        return .{ .start = start, .end = end };
    }

    pub fn signaturesOf(self: *const TypeStore, list: SignatureList) []const Signature {
        return self.signature_pool.items[list.start..list.end];
    }

    /// Construct a function type from a single signature.  Caller passes
    /// the signature struct (with params/return already loaded into the
    /// respective pools via appendSignatureParams).
    pub fn functionType(self: *TypeStore, sig: Signature) !TypeId {
        const sigs = try self.appendSignatures(&.{sig});
        return try self.add(.{ .kind = .function_t, .signatures = sigs });
    }

    // ── Convenience constructors ──────────────────────────

    pub fn stringLiteral(self: *TypeStore, value: []const u8) !TypeId {
        return try self.add(.{
            .kind = .string_literal,
            .literal_value = .{ .string = value },
        });
    }

    pub fn numberLiteral(self: *TypeStore, value: f64) !TypeId {
        return try self.add(.{
            .kind = .number_literal,
            .literal_value = .{ .number = value },
        });
    }

    /// Re-add `lit` (a string/number literal) tagged as a member of enum
    /// `enum_name`, so the facade can surface ts.TypeFlags.EnumLiteral and an
    /// EnumMember symbol. The enum tag is part of interning identity, so the
    /// enum member stays distinct from the bare literal of the same value.
    pub fn enumMemberLiteral(self: *TypeStore, lit: TypeId, enum_name: []const u8, member_name: []const u8) !TypeId {
        var t = self.get(lit).*;
        t.enum_name = enum_name;
        t.name = member_name;
        return try self.add(t);
    }

    pub fn bigintLiteral(self: *TypeStore, value: []const u8) !TypeId {
        return try self.add(.{
            .kind = .bigint_literal,
            .literal_value = .{ .bigint = value },
        });
    }

    pub fn booleanLiteral(self: *TypeStore, value: bool) !TypeId {
        return try self.add(.{
            .kind = .boolean_literal,
            .literal_value = .{ .boolean = value },
        });
    }

    /// Whether a union member participates in subtype reduction.  Limited to
    /// array/tuple types — the common `number[] | never[]` → `number[]` case —
    /// while leaving primitives, literals, objects and named refs untouched
    /// (TS displays many of those unreduced and broad absorption risks
    /// surprising collapses).
    fn subtypeReducible(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id).kind) {
            .array_t, .readonly_array_t, .tuple_t => true,
            else => false,
        };
    }

    pub fn unionOf(self: *TypeStore, members: []const TypeId) !TypeId {
        // Flatten + dedup (cheap: most unions are small).
        var buf = std.ArrayList(TypeId).empty;
        defer buf.deinit(self.gpa);
        for (members) |m| {
            if (m.eq(ID_NEVER)) continue; // `T | never` = `T`
            const t = self.get(m);
            if (t.kind == .union_t) {
                for (self.idsOf(t.list_data)) |inner| {
                    try addUnique(self.gpa, &buf, inner);
                }
            } else {
                try addUnique(self.gpa, &buf, m);
            }
        }
        // `true | false` → `boolean`: TypeScript collapses the full boolean
        // literal union to the base type before any base-type absorption below.
        {
            var has_true = false;
            var has_false = false;
            for (buf.items) |m| {
                const t = self.get(m);
                if (t.kind == .boolean_literal) {
                    if (t.literal_value.boolean) has_true = true else has_false = true;
                }
            }
            if (has_true and has_false) {
                var w: usize = 0;
                var inserted = false;
                for (buf.items) |m| {
                    if (self.get(m).kind == .boolean_literal) {
                        if (!inserted) {
                            buf.items[w] = ID_BOOLEAN;
                            w += 1;
                            inserted = true;
                        }
                    } else {
                        buf.items[w] = m;
                        w += 1;
                    }
                }
                buf.shrinkRetainingCapacity(w);
            }
        }
        // Literal absorption: a literal is subsumed by its broad primitive base
        // when both appear in the union — TS collapses `'a' | string` to `string`
        // (and `Str.A | string` to `string`). Required for no-unsafe-enum-
        // comparison's `Enum | string` / `Enum | number` exemption (an enum whose
        // members are absorbed by their base primitive is no longer an enum type).
        {
            var has_string = false;
            var has_number = false;
            var has_boolean = false;
            var has_bigint = false;
            for (buf.items) |m| {
                if (m.eq(ID_STRING)) has_string = true
                else if (m.eq(ID_NUMBER)) has_number = true
                else if (m.eq(ID_BOOLEAN)) has_boolean = true
                else if (m.eq(ID_BIGINT)) has_bigint = true;
            }
            if (has_string or has_number or has_boolean or has_bigint) {
                var w: usize = 0;
                for (buf.items) |m| {
                    const drop = switch (self.get(m).kind) {
                        .string_literal => has_string,
                        .number_literal => has_number,
                        .boolean_literal => has_boolean,
                        .bigint_literal => has_bigint,
                        else => false,
                    };
                    if (!drop) {
                        buf.items[w] = m;
                        w += 1;
                    }
                }
                buf.shrinkRetainingCapacity(w);
            }
        }
        if (buf.items.len == 0) return ID_NEVER;
        if (buf.items.len == 1) return buf.items[0];
        // any-in-union collapses to any (TS semantics).
        for (buf.items) |m| if (m.eq(ID_ANY)) return ID_ANY;
        // Subtype reduction: drop any member that is a strict subtype of a
        // distinct member (TS keeps the widest type — e.g. `number[] | never[]`
        // → `number[]`).  Primitives/literals are already handled above and are
        // skipped here to avoid surprising collapses of nominal-ish types.
        if (buf.items.len > 1 and buf.items.len <= 32) {
            var w: usize = 0;
            outer: for (buf.items, 0..) |m, i| {
                if (subtypeReducible(self, m)) {
                    for (buf.items, 0..) |other, j| {
                        if (i == j or !subtypeReducible(self, other)) continue;
                        if (!isAssignableTo(self, m, other)) continue;
                        // `m <: other`.  If also `other <: m` they are
                        // equivalent — keep only the earlier index.
                        if (isAssignableTo(self, other, m)) {
                            if (j < i) continue :outer;
                        } else {
                            continue :outer; // strict subtype → drop m
                        }
                    }
                }
                buf.items[w] = m;
                w += 1;
            }
            buf.shrinkRetainingCapacity(w);
            if (buf.items.len == 1) return buf.items[0];
        }
        const list = try self.appendTypeIds(buf.items);
        return try self.add(.{ .kind = .union_t, .list_data = list });
    }

    pub fn arrayOf(self: *TypeStore, elem: TypeId) !TypeId {
        const list = try self.appendTypeIds(&.{elem});
        return try self.add(.{ .kind = .array_t, .list_data = list });
    }

    pub fn readonlyArrayOf(self: *TypeStore, elem: TypeId) !TypeId {
        const list = try self.appendTypeIds(&.{elem});
        return try self.add(.{ .kind = .readonly_array_t, .list_data = list });
    }

    pub fn restOf(self: *TypeStore, inner: TypeId) !TypeId {
        const list = try self.appendTypeIds(&.{inner});
        return try self.add(.{ .kind = .rest_t, .list_data = list });
    }

    pub fn tupleOf(self: *TypeStore, elems: []const TypeId) !TypeId {
        const list = try self.appendTypeIds(elems);
        return try self.add(.{ .kind = .tuple_t, .list_data = list });
    }

    pub fn intersectionOf(self: *TypeStore, members: []const TypeId) !TypeId {
        // Flatten + dedup, mirroring unionOf.
        var buf = std.ArrayList(TypeId).empty;
        defer buf.deinit(self.gpa);
        for (members) |m| {
            const t = self.get(m);
            if (t.kind == .intersection_t) {
                for (self.idsOf(t.list_data)) |inner| {
                    try addUnique(self.gpa, &buf, inner);
                }
            } else {
                try addUnique(self.gpa, &buf, m);
            }
        }
        // `any` / `error` / `never` absorb within an intersection (TS: `any & T`
        // = `any`, `never & T` = `never`; the error type behaves as `any`).
        // Without this, `Enum1.A & string` (where the undefined `Enum1.A` is the
        // error/any type) stays `[any, string]` and reads as string-like — a
        // no-unnecessary-template-expression false positive.
        for (buf.items) |m| if (self.get(m).kind == .never) return ID_NEVER;
        for (buf.items) |m| {
            const k = self.get(m).kind;
            if (k == .any or k == .error_t) return m;
        }
        // A literal subsumes its primitive within an intersection: `string & "x"`
        // is just `"x"`.  Drop the plain primitive when a literal of the same
        // family is present, so the truthy literal isn't masked by a (possibly
        // falsy) primitive (no-unnecessary-condition's isPossiblyFalsy).
        var has_str_lit = false;
        var has_num_lit = false;
        var has_bool_lit = false;
        var has_bigint_lit = false;
        for (buf.items) |m| switch (self.get(m).kind) {
            .string_literal => has_str_lit = true,
            .number_literal => has_num_lit = true,
            .boolean_literal => has_bool_lit = true,
            .bigint_literal => has_bigint_lit = true,
            else => {},
        };
        if (has_str_lit or has_num_lit or has_bool_lit or has_bigint_lit) {
            var w: usize = 0;
            for (buf.items) |m| {
                const drop = switch (self.get(m).kind) {
                    .string => has_str_lit,
                    .number => has_num_lit,
                    .boolean => has_bool_lit,
                    .bigint => has_bigint_lit,
                    else => false,
                };
                if (!drop) {
                    buf.items[w] = m;
                    w += 1;
                }
            }
            buf.items.len = w;
        }
        // Incompatible primitive families have no inhabitants (`string & number`,
        // `"x" & 123`) → never.  Checked after flatten so a nested intersection's
        // primitive is seen against a sibling literal.
        var fam_str = false;
        var fam_num = false;
        var fam_bool = false;
        var fam_bigint = false;
        for (buf.items) |m| switch (self.get(m).kind) {
            .string, .string_literal => fam_str = true,
            .number, .number_literal => fam_num = true,
            .boolean, .boolean_literal => fam_bool = true,
            .bigint, .bigint_literal => fam_bigint = true,
            else => {},
        };
        var fam_count: u32 = 0;
        if (fam_str) fam_count += 1;
        if (fam_num) fam_count += 1;
        if (fam_bool) fam_count += 1;
        if (fam_bigint) fam_count += 1;
        if (fam_count >= 2) return ID_NEVER;
        if (buf.items.len == 0) return ID_NEVER;
        if (buf.items.len == 1) return buf.items[0];
        const list = try self.appendTypeIds(buf.items);
        return try self.add(.{ .kind = .intersection_t, .list_data = list });
    }

    pub fn objectOf(self: *TypeStore, props: []const ObjectProp) !TypeId {
        if (props.len == 0) return try self.add(.{ .kind = .object_t });
        // Append props to the object prop pool.
        const start: u32 = @intCast(self.object_prop_pool.items.len);
        try self.object_prop_pool.appendSlice(self.gpa, props);
        const end: u32 = @intCast(self.object_prop_pool.items.len);
        return try self.add(.{
            .kind = .object_t,
            .object_props = .{ .start = start, .end = end },
        });
    }

    pub fn typeRef(self: *TypeStore, name: []const u8, args: []const TypeId) !TypeId {
        const list = if (args.len == 0) TypeIdList.empty else try self.appendTypeIds(args);
        return try self.add(.{ .kind = .type_ref, .name = name, .list_data = list });
    }

    /// A type-parameter type carrying its constraint (in `list_data[0]`, empty
    /// when unconstrained). `name` is the parameter name (`T`). Distinct from a
    /// `type_ref` so the facade's isTypeParameter / getConstraint work and
    /// assignability can treat `concrete → type_param` as not-assignable.
    pub fn typeParam(self: *TypeStore, name: []const u8, constraint: TypeId) !TypeId {
        const list = if (constraint == .none) TypeIdList.empty else try self.appendTypeIds(&.{constraint});
        return try self.add(.{ .kind = .type_param, .name = name, .list_data = list });
    }

    fn addUnique(gpa: std.mem.Allocator, buf: *std.ArrayList(TypeId), id: TypeId) !void {
        for (buf.items) |x| if (x.eq(id)) return;
        try buf.append(gpa, id);
    }
};

// ── Assignability ────────────────────────────────────────────

/// Is `source` assignable to `target`?  Approximates TS's `isAssignableTo`
/// to the depth needed for the type-aware rule family.
pub fn isAssignableTo(store: *const TypeStore, source: TypeId, target: TypeId) bool {
    if (source.eq(target)) return true;
    if (isUnknown(store, target)) return true;
    if (isAny(store, source) or isAny(store, target)) return true;
    const s = store.get(source);
    if (s.kind == .never) return true;
    // Union source: every member must be assignable to target.
    if (s.kind == .union_t) {
        for (store.idsOf(s.list_data)) |m| {
            if (!isAssignableTo(store, m, target)) return false;
        }
        return true;
    }
    // Union target: source assignable to ANY member.
    const t = store.get(target);
    if (t.kind == .union_t) {
        for (store.idsOf(t.list_data)) |m| {
            if (isAssignableTo(store, source, m)) return true;
        }
        return false;
    }
    // Intersection target: source must be assignable to EVERY member.
    if (t.kind == .intersection_t) {
        for (store.idsOf(t.list_data)) |m| {
            if (!isAssignableTo(store, source, m)) return false;
        }
        return true;
    }
    // Intersection source: ANY member assignable to target is enough.
    if (s.kind == .intersection_t) {
        for (store.idsOf(s.list_data)) |m| {
            if (isAssignableTo(store, m, target)) return true;
        }
        return false;
    }
    // Literal → primitive of same kind.
    if (s.kind == .string_literal and t.kind == .string) return true;
    if (s.kind == .number_literal and t.kind == .number) return true;
    if (s.kind == .boolean_literal and t.kind == .boolean) return true;
    if (s.kind == .bigint_literal and t.kind == .bigint) return true;
    // Literal → same-value literal of the same kind.
    if (s.kind == .string_literal and t.kind == .string_literal) {
        return std.mem.eql(u8, s.literal_value.string, t.literal_value.string);
    }
    if (s.kind == .number_literal and t.kind == .number_literal) {
        return s.literal_value.number == t.literal_value.number;
    }
    if (s.kind == .boolean_literal and t.kind == .boolean_literal) {
        return s.literal_value.boolean == t.literal_value.boolean;
    }
    if (s.kind == .bigint_literal and t.kind == .bigint_literal) {
        return std.mem.eql(u8, s.literal_value.bigint, t.literal_value.bigint);
    }
    // Structural object: target's every prop present + assignable in source.
    if (s.kind == .object_t and t.kind == .object_t) {
        const s_props = store.propsOf(s.object_props);
        for (store.propsOf(t.object_props)) |tp| {
            const sp = findProp(s_props, tp.name) orelse {
                // Missing prop: only ok if the target prop is optional.
                if (tp.optional) continue;
                return false;
            };
            // Optional source + required target: source may not have a value.
            if (sp.optional and !tp.optional) return false;
            if (!isAssignableTo(store, sp.type_id, tp.type_id)) return false;
        }
        return true;
    }
    // Array/tuple covariance (sound for read-only positions).
    if ((s.kind == .array_t or s.kind == .readonly_array_t) and
        (t.kind == .array_t or t.kind == .readonly_array_t))
    {
        // `readonly T[]` is NOT assignable to `T[]` (the mutable form
        // permits writes the readonly type forbids).
        if (s.kind == .readonly_array_t and t.kind == .array_t) return false;
        const se = store.idsOf(s.list_data);
        const te = store.idsOf(t.list_data);
        if (se.len == 0 or te.len == 0) return false;
        return isAssignableTo(store, se[0], te[0]);
    }
    // Tuple ↔ tuple: element-wise covariant.
    if (s.kind == .tuple_t and t.kind == .tuple_t) {
        const se = store.idsOf(s.list_data);
        const te = store.idsOf(t.list_data);
        if (se.len != te.len) return false;
        for (se, te) |a, b| if (!isAssignableTo(store, a, b)) return false;
        return true;
    }
    // Tuple → array: tuple T1, T2, ... assignable to (T1 | T2 | ...)[].
    if (s.kind == .tuple_t and (t.kind == .array_t or t.kind == .readonly_array_t)) {
        const elems = store.idsOf(s.list_data);
        const te = store.idsOf(t.list_data);
        if (te.len == 0) return false;
        for (elems) |e| if (!isAssignableTo(store, e, te[0])) return false;
        return true;
    }
    // type_ref: same NAME and assignable type args (covariant approximation).
    if (s.kind == .type_ref and t.kind == .type_ref) {
        if (!std.mem.eql(u8, s.name, t.name)) return false;
        const sa = store.idsOf(s.list_data);
        const ta = store.idsOf(t.list_data);
        if (sa.len != ta.len) return false;
        for (sa, ta) |a, b| if (!isAssignableTo(store, a, b)) return false;
        return true;
    }
    // Function variance:
    //   - target's param count <= source's param count (extra source
    //     params are allowed — JS callers can ignore).
    //   - parameters contravariant: target_param assignable to source_param.
    //   - return covariant: source_return assignable to target_return.
    if (s.kind == .function_t and t.kind == .function_t) {
        const s_sigs = store.signaturesOf(s.signatures);
        const t_sigs = store.signaturesOf(t.signatures);
        if (s_sigs.len == 0 or t_sigs.len == 0) return false;
        // Use the first overload of each — TSe rule family doesn't
        // exercise overload matrix selection.
        const ss = s_sigs[0];
        const ts = t_sigs[0];
        const s_params = store.signatureParamsOf(ss);
        const t_params = store.signatureParamsOf(ts);
        if (t_params.len > s_params.len) return false;
        for (t_params, 0..) |tp, i| {
            // contravariant: target_param ≤ source_param.
            if (!isAssignableTo(store, tp, s_params[i])) return false;
        }
        return isAssignableTo(store, ss.return_type, ts.return_type);
    }
    return false;
}

fn findProp(props: []const ObjectProp, name: []const u8) ?ObjectProp {
    for (props) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

// ── Anyness — the core query for no-unsafe-* rules ──────────

/// Returns true when the type is `any` or contains `any` anywhere reachable
/// without a barrier (function return type counts; opaque type ref payload
/// does not — we don't follow refs here).
pub fn isAny(store: *const TypeStore, id: TypeId) bool {
    if (id.eq(ID_ANY)) return true;
    const t = store.get(id);
    return t.kind == .any;
}

/// True when the type is `unknown` or contains `unknown` reachable at
/// any composite position.  `unknown` is the recommended safe target
/// for any-typed values (e.g. `function f(x: unknown)` is the typed
/// API contract that says "I'll narrow this before use"), so the
/// unsafe-* rules must suppress when the destination type accepts
/// any via an unknown slot.
pub fn isUnknown(store: *const TypeStore, id: TypeId) bool {
    if (id.eq(ID_UNKNOWN)) return true;
    return store.get(id).kind == .unknown;
}

/// True when the type is the built-in `Function` type — typescript-eslint
/// flags calling values of type `Function` because the type is callable
/// without signature constraints (any args, any return).  This catches
/// the simple case (`const f: Function = ...; f()`) but not custom
/// subtypes (`interface MyFn extends Function {}`) which would need
/// interface heritage tracking we don't yet do.
pub fn isFunctionRef(store: *const TypeStore, id: TypeId) bool {
    const t = store.get(id);
    if (t.kind != .type_ref) return false;
    return std.mem.eql(u8, t.name, "Function");
}

/// True when the type is the "error" type — unresolved type-name
/// reference.  TSe's rules fire `error*` messageIds on these.
pub fn isError(store: *const TypeStore, id: TypeId) bool {
    if (id.eq(ID_ERROR)) return true;
    return store.get(id).kind == .error_t;
}

/// True when the type is `Promise<T>` (any T or T contains any).
pub fn isPromiseOfAny(store: *const TypeStore, id: TypeId) bool {
    const t = store.get(id);
    if (t.kind != .type_ref) return false;
    if (!std.mem.eql(u8, t.name, "Promise")) return false;
    const args = store.idsOf(t.list_data);
    if (args.len == 0) return false;
    return containsAny(store, args[0]);
}

/// True when the type is a `Promise<…>` reference (any type args, or none).
/// Looser than isPromiseOfAny — used to recognise a Promise receiver for
/// contextual typing of `.then`/`.catch` rejection callbacks.
pub fn isPromiseRef(store: *const TypeStore, id: TypeId) bool {
    const t = store.get(id);
    return t.kind == .type_ref and std.mem.eql(u8, t.name, "Promise");
}

/// True when the type is `any[]` / `readonly any[]` / `Array<any>` /
/// `ReadonlyArray<any>` — TSe's "any array" classification.
pub fn isAnyArray(store: *const TypeStore, id: TypeId) bool {
    const t = store.get(id);
    switch (t.kind) {
        .array_t, .readonly_array_t => {
            const elems = store.idsOf(t.list_data);
            return elems.len > 0 and containsAny(store, elems[0]);
        },
        .type_ref => {
            if (std.mem.eql(u8, t.name, "Array") or std.mem.eql(u8, t.name, "ReadonlyArray")) {
                const args = store.idsOf(t.list_data);
                return args.len > 0 and containsAny(store, args[0]);
            }
            return false;
        },
        else => return false,
    }
}

pub fn containsUnknown(store: *const TypeStore, id: TypeId) bool {
    if (isUnknown(store, id)) return true;
    const t = store.get(id);
    return switch (t.kind) {
        .union_t, .intersection_t => for (store.idsOf(t.list_data)) |m| {
            if (containsUnknown(store, m)) break true;
        } else false,
        .array_t, .readonly_array_t, .tuple_t => for (store.idsOf(t.list_data)) |m| {
            if (containsUnknown(store, m)) break true;
        } else false,
        // type_ref with type args: peek args.  Catches Set<unknown>,
        // Promise<unknown>, etc.
        .type_ref => for (store.idsOf(t.list_data)) |m| {
            if (containsUnknown(store, m)) break true;
        } else false,
        else => false,
    };
}

/// True when the type has any `any` reachable in the local shape: unions
/// where one member is any, intersections (any & T = any), generics whose
/// type arguments contain any (`Promise<any>`, `Set<any>`).  Used by
/// no-unsafe-assignment to flag `const x: { a: number } = { a: anyVal }`
/// when the source has any in the corresponding slot.
pub fn containsAny(store: *const TypeStore, id: TypeId) bool {
    if (isAny(store, id)) return true;
    const t = store.get(id);
    return switch (t.kind) {
        .union_t, .intersection_t => for (store.idsOf(t.list_data)) |m| {
            if (containsAny(store, m)) break true;
        } else false,
        .array_t, .readonly_array_t, .tuple_t => for (store.idsOf(t.list_data)) |m| {
            if (containsAny(store, m)) break true;
        } else false,
        // Walk generic type args: `Promise<any>`, `Set<any>`, etc.
        .type_ref => for (store.idsOf(t.list_data)) |m| {
            if (containsAny(store, m)) break true;
        } else false,
        // Walk object properties: `{ a: any }` should report anyness.
        .object_t => for (store.propsOf(t.object_props)) |p| {
            if (containsAny(store, p.type_id)) break true;
        } else false,
        else => false,
    };
}

/// True when the type reaches `error` at any composite position.  TSe's
/// unsafe-* rules fire `error*` messageIds on these — an unresolved
/// type name reads as `error typed` in the diagnostic data.
pub fn containsError(store: *const TypeStore, id: TypeId) bool {
    if (isError(store, id)) return true;
    const t = store.get(id);
    return switch (t.kind) {
        .union_t, .intersection_t,
        .array_t, .readonly_array_t, .tuple_t,
        .type_ref => for (store.idsOf(t.list_data)) |m| {
            if (containsError(store, m)) break true;
        } else false,
        .object_t => for (store.propsOf(t.object_props)) |p| {
            if (containsError(store, p.type_id)) break true;
        } else false,
        else => false,
    };
}

test "TypeStore singletons" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(isAny(&store, ID_ANY));
    try std.testing.expect(!isAny(&store, ID_NUMBER));
    try std.testing.expect(!containsAny(&store, ID_STRING));
}

test "TypeStore union flattens and collapses any" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit();
    const num_or_str = try store.unionOf(&.{ ID_NUMBER, ID_STRING });
    try std.testing.expect(!containsAny(&store, num_or_str));
    const with_any = try store.unionOf(&.{ ID_NUMBER, ID_ANY });
    try std.testing.expect(with_any.eq(ID_ANY));
}

test "TypeStore array of any flagged by containsAny" {
    var store = try TypeStore.init(std.testing.allocator);
    defer store.deinit();
    const arr_any = try store.arrayOf(ID_ANY);
    try std.testing.expect(!isAny(&store, arr_any));
    try std.testing.expect(containsAny(&store, arr_any));
}

