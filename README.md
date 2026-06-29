# ez-checker

[![CI](https://github.com/ericsssan/ez-checker/actions/workflows/ci.yml/badge.svg)](https://github.com/ericsssan/ez-checker/actions/workflows/ci.yml)
[![TypeScript corpus](https://img.shields.io/badge/TypeScript_corpus-84.3%25-brightgreen)](#conformance)
[![primitive types](https://img.shields.io/badge/primitive_types-90.9%25-brightgreen)](#conformance)

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
`Partial`, `Required`, `Readonly`, `Pick`, `Omit`, `Exclude`, `Extract`, `NonNullable`, `Record`, `ReturnType`, `Parameters`, `Awaited`.

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
| All expression types | 554,170 | 657,474 | **84.3%** |
| Primitive types (sub-metric) | 338,560 | 372,262 | **90.9%** |

A ratchet (`oracle/baseline.lock`) records these floors; `zig build test-oracle` fails if any metric regresses, and CI enforces it on every push and pull request. Sweep the corpus with `zig build run-oracle`; raise the floor after a genuine gain with `zig build save-baseline`.

---

## Known gaps

See [open issues](https://github.com/ericsssan/ez-checker/issues/9) for the full tracked list. Short version:

- `ConstructorParameters<T>` and `InstanceType<T>` not yet implemented
- `as const` on object literals (arrays work; objects do not)
- Optional chaining (`?.`) does not add `| undefined` to the result type
- `==`/`!=` (loose equality) does not narrow
- `throw` does not narrow subsequent code
- Class + interface declaration merging not supported
- `declare module` / `declare global` augmentation not supported
- Overload resolution picks the first matching signature, not the best one
- Global built-in types (~30 hand-curated entries; no full lib.dom or lib.es*)

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

// Init from an already-parsed file.
var checker = try Checker.init(allocator, &ast, &semantic_result);
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

checker.module_resolver = .{
    .ctx        = @ptrCast(my_cache),
    .resolve_fn = &resolveImpl,
};
```

---

## License

MIT
