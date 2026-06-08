# return-arraylist-items

`return list.items` — returning the `.items` slice of a local `ArrayList` directly leaks the backing allocation. The caller receives a `[]T` slice but has no `ArrayList` handle to call `.deinit()` on, so the capacity bytes are permanently lost.

## What the rule checks

The rule fires on the 5-token pattern `return identifier . items ;`. It suppresses `self` and `this` receivers because those access a struct field, not a local `ArrayList`.

`return list.toOwnedSlice()` does **not** fire — the pattern ends with `l_paren`, not `semicolon`.

## Why it matters

`std.ArrayList.initCapacity(allocator, n)` allocates `n` elements of capacity. Returning `.items` gives the caller a slice over only the used portion (`items.len` bytes). When the caller frees that slice with `allocator.free()`, the allocator's internal bookkeeping verifies the freed size matches the allocated size — but since `.items` is shorter than the full capacity allocation, this either:

1. **Leaks** the extra capacity bytes permanently (if the allocator skips the size check), or
2. **Panics** with "Allocation size mismatch" in Debug/Safe builds.

`list.toOwnedSlice()` calls `realloc` to shrink the backing buffer to exactly `items.len` bytes, then transfers ownership to the caller. That is the only safe way to return the data.

## Real-world instance

- **oven-sh/bun#23885** (`toUTF8AllocWithType`): built a local `var list = try std.ArrayList(u8).initCapacity(allocator, n)` and returned `list.items`. The caller called `allocator.free()` on the slice, freeing only `items.len` bytes; the extra capacity from `initCapacity` leaked on every call. Fix: `return list.toOwnedSlice()`.

## Fix

```zig
// Instead of:
return list.items;

// Transfer ownership:
return list.toOwnedSlice();

// Or if you want a sentinel-terminated slice:
return list.toOwnedSliceSentinel(0);
```
