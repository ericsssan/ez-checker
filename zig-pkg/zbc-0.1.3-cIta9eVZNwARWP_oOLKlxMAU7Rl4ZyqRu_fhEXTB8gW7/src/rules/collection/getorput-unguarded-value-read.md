# getorput-unguarded-value-read

`std.HashMap.getOrPut` (and its `Adapted`/`Context` variants) returns a
`GetOrPutResult` containing two fields:

- `found_existing: bool` — true iff the key was already in the map.
- `value_ptr: *V` — pointer to the value slot.

When `found_existing == false` the map just inserted a new slot and
`value_ptr.*` is **uninitialised**.  Reading it before checking
`found_existing` is undefined behaviour.

Write-only access — `gop.value_ptr.* = value;` — is safe without the
guard because it initialises the slot.  Compound assignments
(`gop.value_ptr.* += 1`, `|= flags`, etc.) are **not** safe: they read
the old value first.

## Why this matters

The pattern is pervasive in caches, counters, and accumulators:

```zig
const gop = try map.getOrPut(key);
gop.value_ptr.* += 1;   // counts occurrences — UB when key is new
```

The bug is silent in debug builds (Zig zero-fills new allocations in
many allocators) and intermittent in release builds (depends on the
heap layout of the freshly-inserted slot).  It surfaces as wrong counts
or occasional corruption rather than an immediate crash, making it
hard to diagnose.

## Canonical bug

```zig
const gop = try map.getOrPut(key);
return gop.value_ptr.*;          // UB: slot uninitialised when key is new
```

## Fix

Always check `found_existing` before reading:

```zig
const gop = try map.getOrPut(key);
if (!gop.found_existing) gop.value_ptr.* = 0;   // initialise
gop.value_ptr.* += 1;                            // now safe to read
```

Or branch explicitly:

```zig
const gop = try map.getOrPut(key);
if (gop.found_existing) {
    gop.value_ptr.* += delta;
} else {
    gop.value_ptr.* = initial_value;
}
```

## Detection

Per-function token walk:

1. Find `const/var <name> = [try] <chain>.getOrPut*(...)`.
2. After the statement's `;`, scan for `<name>.value_ptr`.
3. Track whether `<name>.found_existing` was referenced first.
4. If `value_ptr.*` is accessed as a READ (not a plain `= …`
   assignment) before any `found_existing` reference, fire.

Suppressed when:

- `<name>.found_existing` appears anywhere before the read.
- The access is a bare write: `<name>.value_ptr.* = <expr>;`.

Note: `getOrPutValue` and `*AssumeCapacity` variants return the value
directly rather than a `GetOrPutResult`, so they are not checked.
