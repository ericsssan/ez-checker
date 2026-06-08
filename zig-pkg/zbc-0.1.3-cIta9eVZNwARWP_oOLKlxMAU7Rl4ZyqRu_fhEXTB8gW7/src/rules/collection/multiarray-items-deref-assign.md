# multiarray-items-deref-assign

`.items(.FIELD)[index].* = VALUE` on a `MultiArrayList` — dereferencing the result of `MultiArrayList.items(.field)` as if it were a slice of pointers. `items(.field)` returns a `[]FieldType` (a slice of values, not pointers); `[index].*` interprets the field value as a memory address and writes through it, which is undefined behaviour.

## What the rule checks

The rule fires when the pattern `.items(.<field>)[<expr>].* =` appears — specifically, when a `.items(.FIELD)` call (the 5-token `.items ( . FIELD )` form used for `MultiArrayList`) is immediately indexed with `[expr]` and then dereference-assigned with `.* =`.

It does not fire when:
- The indexing result is assigned directly: `.items(.hash)[i] = v` — correct form
- The dereference is a read, not a write: `.items(.ptr)[i].*` — read-only deref

## Why it matters

`std.MultiArrayList.items(.field)` returns a `[]FieldType` slice — a slice of the field **values**, not pointers-to-field. The `.* =` dereference attempts to use the field value itself as a pointer and write through it. For numeric fields (u32, u64, enum) this is always undefined behaviour.

The bug typically arises from copy-pasting code that worked on a regular `[]T` (slice of pointers) and applying it to a `MultiArrayList.items(...)` result without updating the dereference style.

## Real-world instance

- **ziglang/zig#22968** (`ArrayHashMap.setKey` with `store_hash=true`): `self.entries.items(.hash)[index].* = checkedHash(ctx, key_ptr.*)`. The `.hash` field is `u32`; `.items(.hash)` returns `[]u32`. The `.*` tried to dereference a u32 hash value as a memory address. Fix: removed `.*`, using direct assignment.

## Fix

```zig
// Instead of (UB — treats field value as pointer):
self.entries.items(.hash)[index].* = checkedHash(ctx, key_ptr.*);

// Direct assignment — the correct form for MultiArrayList field values:
self.entries.items(.hash)[index] = checkedHash(ctx, key_ptr.*);
```
