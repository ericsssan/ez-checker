# hashmap-iter-mutation

Modifying a `HashMap` while iterating over it (via `iterator()`,
`keyIterator()`, or `valueIterator()`) invalidates the iterator's
internal cursor.  Subsequent calls to `iter.next()` have undefined
behaviour — on Zig's open-addressing hash table the cursor may
revisit the same slot, skip slots entirely, or run off the end.

## Why this matters

Zig's `HashMap` uses open addressing.  The iterator stores a numeric
cursor into the backing array.  Any mutation that changes the load
factor — adding or removing entries — may shift or tombstone slots,
making the cursor stale.  Unlike a `std.ArrayList` where a realloc
is required before items move (so no-realloc ops are safe), even a
`remove` on a HashMap can silently corrupt an active iterator.

The failure mode is non-deterministic and load-factor-dependent,
making it very hard to reproduce from a test suite.

## Canonical bug

```zig
var iter = map.iterator();
while (iter.next()) |entry| {
    if (shouldRemove(entry.value_ptr.*)) {
        _ = map.remove(entry.key_ptr.*);  // ← invalidates iter
    }
}
```

## Fix

Collect the keys to remove in a separate list, then remove after
the loop completes:

```zig
var to_remove = std.ArrayList(K).init(allocator);
defer to_remove.deinit();

var iter = map.iterator();
while (iter.next()) |entry| {
    if (shouldRemove(entry.value_ptr.*)) {
        try to_remove.append(entry.key_ptr.*);
    }
}
for (to_remove.items) |key| {
    _ = map.remove(key);
}
```

Or convert to a snapshot first (`map.keys()` / `map.values()`).

## Detection

Per-function token walk:

1. Find `const/var <iter> = <recv>.<iter-method>()` where
   `iter-method ∈ {iterator, keyIterator, valueIterator}`.
   Limited to single-identifier receivers.
2. Scan forward for `while (<iter>.next()) [|...|]` loop headers.
3. Inside the while body, scan for `<recv>.<mutate>(` at the same
   lexical depth (nested blocks are skipped).
4. Fire at the mutation call site.

Mutate methods: `put`, `putAssumeCapacity`, `putNoClobber`,
`putNoClobberAssumeCapacity`, `remove`, `removeByPtr`, `fetchPut`,
`fetchRemove`, `swapRemove`, `clearAndFree`, `clearRetainingCapacity`.

Deliberately omitted: `*AssumeCapacity` put variants — the key is
already present by contract, so no rehash occurs.
