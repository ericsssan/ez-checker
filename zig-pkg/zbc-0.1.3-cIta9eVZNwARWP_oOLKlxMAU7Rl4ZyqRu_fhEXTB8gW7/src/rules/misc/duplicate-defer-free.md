# duplicate-defer-free

`defer allocator.free(X)` appearing twice at the same level in a function body — both defers fire at function exit in LIFO order, freeing `X` twice.

## What the rule checks

The rule scans each function body for the 7-token pattern `defer identifier . free ( identifier )` at the outermost brace depth (depth 1). It fires at the second occurrence when the same `(allocator, slice)` identifier pair appears more than once.

It does not fire when:
- The same allocator frees different slices
- Different allocators free the same slice name
- The `free` calls appear inside nested blocks (`if`/`while`/etc. at depth 2+), since those are scoped to their enclosing block and cannot both fire on the same path

## Why it matters

Zig's `defer` runs at the end of the enclosing block in LIFO (last-in-first-out) order. When two `defer allocator.free(X)` statements appear at the top level of the same function body:

1. Second defer fires first: `allocator.free(X)` — X is freed
2. First defer fires: `allocator.free(X)` — X is freed again → **double-free**

A double-free is undefined behaviour: the allocator's bookkeeping is corrupted, and subsequent allocations may return the same memory that is still in use elsewhere, leading to silent data corruption or crashes.

This is almost always a copy-paste error: the developer duplicated a block of code that included the `defer`, forgetting to remove the original.

## Real-world instance

- **oven-sh/bun#22978** (`createArgv`): two separate `defer allocator.free(args)` statements existed in the same function body — one near the top and one added later. Both fired at function exit, causing a double-free of the argv allocation.

## Fix

```zig
// Instead of:
fn createArgv(allocator: std.mem.Allocator) ![][]u8 {
    const args = try allocator.alloc([]u8, 10);
    defer allocator.free(args); // ← keep this one
    // ... code ...
    defer allocator.free(args); // ← remove duplicate
    return args;
}

// Remove the duplicate:
fn createArgv(allocator: std.mem.Allocator) ![][]u8 {
    const args = try allocator.alloc([]u8, 10);
    defer allocator.free(args);
    // ... code ...
    return args;
}
```
