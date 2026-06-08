# adjacent-decl-same-source-field

Two consecutive `const` declarations that both bind the same struct field via `orelse`, but assign it to differently-named variables — the second binding silently aliases the first instead of reading the intended field.

## What the rule checks

The rule fires when two adjacent `const VAR = STRUCT.FIELD orelse ...` statements share the same `STRUCT` and `FIELD` but use different variable names. The pattern it matches is:

```
const VAR1 = STRUCT . FIELD orelse EXPR ;
const VAR2 = STRUCT . FIELD orelse EXPR
```

It does **not** fire when:
- The fields differ: `const user = uri.user orelse ""; const password = uri.password orelse ""`
- The structs differ: `const a = x.field orelse ""; const b = y.field orelse ""`
- The declarations are non-adjacent (another statement between them)

## Why it matters

The pattern most often arises from copy-paste: the programmer duplicates a `const X = recv.fieldA orelse ...` declaration, renames the variable to reflect a different semantic (`password` instead of `user`), but forgets to update the field accessor. Both variables now hold the same value, and the intended field (`recv.fieldB`) is never read. This is a silent semantic error — the code compiles and runs without any immediate failure.

## Real-world instance

- **ziglang/zig#25099**: When parsing a URI, two declarations were written:
  ```zig
  const user = uri.user orelse "";
  const password = uri.user orelse "";  // intended: uri.password
  ```
  The `password` variable always held the username value; `uri.password` was never accessed. Authentication using these variables would silently compare against the wrong field.

## Fix

```zig
// Instead of (both bind uri.user):
const user = uri.user orelse "";
const password = uri.user orelse "";

// Fix the copy-paste error:
const user = uri.user orelse "";
const password = uri.password orelse "";
```
