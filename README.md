# ez-checker

[![CI](https://github.com/ericsssan/ez-checker/actions/workflows/ci.yml/badge.svg)](https://github.com/ericsssan/ez-checker/actions/workflows/ci.yml)
[![TypeScript corpus](https://img.shields.io/badge/TypeScript_corpus-84.5%25-brightgreen)](#conformance)
[![primitive types](https://img.shields.io/badge/primitive_types-91.0%25-brightgreen)](#conformance)

A reimplementation of the TypeScript type checker. Just the type system: infer the type of any expression, resolve declarations, narrow through control flow. No emit, no diagnostics, no `tsconfig.json`.

Originally extracted from the [Ez](https://github.com/ericsssan/Ez) linter, but the type inference engine is general-purpose — usable by linters, compilers, language servers, or any tool that needs to reason about TypeScript types.

Built on [es-parser](https://github.com/ericsssan/es-parser). Written in Zig.

---

## What it implements

**Expression inference**
Literals, template literals, arrays, objects, functions, classes, binary/unary operators, ternary, assignments, await, sequence, casts (`as`, `satisfies`, `!`).

**Type resolution**
Primitives, arrays, tuples, union, intersection, object types, function types, `typeof`, `keyof`, indexed access (`T[K]`), mapped types, conditional types (including `infer`), template literal types, generic type references, recursive type aliases.

**Utility types**
`Partial`, `Required`, `Readonly`, `Pick`, `Omit`, `Exclude`, `Extract`, `NonNullable`, `Record`, `ReturnType`, `Parameters`, `Awaited`, `ConstructorParameters`, `InstanceType`.

**Control-flow narrowing**
Null/undefined checks, `typeof` guards, `instanceof`, type predicates (`x is T`), assertion functions (`asserts x`), discriminated unions, truthiness, assignment narrowing, early-return narrowing.

**Declarations**
Variables, functions (with overloads), classes (instance + static, inheritance), interfaces (extends, call/construct signatures, index signatures, declaration merging), type aliases, enums (numeric, string, mixed), namespaces (declaration merging), imports.

**Cross-file resolution**
Optional. Implement `ModuleResolver` and set `Checker.module_resolver` to resolve types from imported modules lazily.

---

## Conformance

Measured against the TypeScript compiler itself: for every expression in the [microsoft/TypeScript](https://github.com/microsoft/TypeScript) test corpus, ez-checker infers a type and compares it — string for string — against the `.types` baseline `tsc` emits for that same expression.

| Metric | Correct | Total | Rate |
| --- | --- | --- | --- |
| All expression types | 555,634 | 657,474 | **84.5%** |
| Primitive types (sub-metric) | 338,601 | 372,262 | **91.0%** |

A ratchet (`oracle/baseline.lock`) records these floors; `zig build test-oracle` fails if any metric regresses, and CI enforces it on every push and pull request. Sweep the corpus with `zig build run-oracle`; raise the floor after a genuine gain with `zig build save-baseline`.

---

## Known gaps

Every gap originally tracked here has since been implemented; the list below is
what the checker still does not do, re-audited against the numbers in the table
above.

- `declare module` / `declare global` augmentation is only partial — a same-named `interface` in a global block merges, but general module augmentation does not
- Cross-file resolution (opt-in via `ModuleResolver`) does not cover import-equals aliases, `node_modules` packages, or CommonJS `exports` shapes
- JS-file semantics: a prototype-based constructor (`C.prototype.m = ...`, no `this.x` in the body) is not recognised as class-like, and plain JS functions have no polymorphic `this` type
- Global built-in types are hand-curated (globals, DOM, `Intl`, `Temporal`, typed arrays). Anything unmodelled resolves to an opaque named type rather than a structural one — there is no full `lib.dom` / `lib.es*` ingest
- Corpus-wide, ~9% of expressions still yield no type at all and ~5% yield one that differs from `tsc`; `zig build run-oracle` prints the breakdown by category

Implemented since this list was first written: `ConstructorParameters<T>` and
`InstanceType<T>`, `as const` on object literals, optional-chaining `| undefined`,
`==` / `!=` narrowing, `throw` narrowing, class + interface declaration merging,
and best-match (not first-match) overload resolution.

---

## Usage

`build.zig.zon`:
```zig
.dependencies = .{
    .ez_checker = .{ .path = "../ez-checker" },
    .es_parser  = .{ .path = "../es-parser" },
},
```

`build.zig`:
```zig
const ez_checker_mod = b.dependency("ez_checker", .{
    .target = target,
    .optimize = .ReleaseFast,
}).module("ez-checker");

your_module.addImport("ez_checker", ez_checker_mod);
```

---

## API

```zig
const ez = @import("ez_checker");
const Checker  = ez.Checker;
const types    = ez.types;

// Init from an already-parsed file. The fourth argument is `CheckerOpts`
// (language, target/lib, strictness); `.{}` takes the defaults.
var checker = try Checker.init(allocator, &ast, &semantic_result, .{});
defer checker.deinit();

// Optional: wire cross-file resolution.
checker.file_path      = "/abs/path/to/file.ts";
checker.module_resolver = my_module_cache.resolver();

// Query the type of any expression node.
const ty: types.TypeId = checker.typeOf(node_index);

// Classify the result.
if (types.isAny(&checker.store, ty))          { /* any */ }
if (types.containsAny(&checker.store, ty))    { /* any somewhere inside */ }
if (types.isAssignableTo(&checker.store, src, dst)) { /* assignable */ }
```

### `ModuleResolver`

Implement this to enable cross-file type resolution:

```zig
fn resolveImpl(
    ctx: *anyopaque,
    from_dir: []const u8,
    module_spec: []const u8,
    export_name: []const u8,
    local_store: *types.TypeStore,
    gpa: std.mem.Allocator,
) ?types.TypeId {
    const cache: *MyCache = @ptrCast(@alignCast(ctx));
    return cache.resolve(from_dir, module_spec, export_name, local_store, gpa);
}

fn moduleSourceImpl(
    ctx: *anyopaque,
    from_dir: []const u8,
    module_spec: []const u8,
) ?[]const u8 {
    const cache: *MyCache = @ptrCast(@alignCast(ctx));
    return cache.source(from_dir, module_spec);
}

checker.module_resolver = .{
    .ctx               = @ptrCast(my_cache),
    .resolve_fn        = &resolveImpl,
    .module_source_fn  = &moduleSourceImpl,
};
```

---

## License

MIT
