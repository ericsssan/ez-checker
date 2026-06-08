# hashmap-getptr-rehash

A `const <X> = <map>.getPtr(...);` (or `getOrPut`, `getOrPutValue`,
`getOrPutAssumeCapacity`, `getOrPutAdapted`) borrows a pointer into
the map's internal storage.  A subsequent receiver-matched
`<map>.<mutate>(...)` call — where `mutate ∈ {put,
putAssumeCapacity, putNoClobber, putNoClobberAssumeCapacity, remove,
removeByPtr, fetchPut, fetchRemove, swapRemove}` — may rehash the
table and invalidate `<X>`.  A later read of `<X>` is a
use-after-free against the table's storage.

## Why this matters

Zig std's HashMap documents that pointers returned by `getPtr` and
the `value_ptr` / `key_ptr` fields of `GetOrPutResult` are valid
ONLY until the next call that may modify the table's capacity.  This
is the single most common Zig footgun on hashmaps:

- The compiler can't help — the borrow looks like a plain pointer.
- The failure is intermittent — only fires when the `put` happens to
  trigger a resize (which depends on load factor and key distribution
  in production data, not in unit tests).
- The symptom is data corruption or segfault far from the cause
  (heap-allocator-dependent), often on a different field of an
  apparently-unrelated struct.

## Canonical bug

```zig
const p = map.getPtr(key) orelse return error.NotFound;  // ← borrow
try map.put(other_key, other_value);                      // ← may rehash → invalidates `p`
p.* = newValue;                                            // ← UAF
```

The `p.* = newValue` write may land in freed heap, in another
allocation, or on the now-relocated cell — depending on whether the
`put` happened to trigger a grow.  Even when it doesn't immediately
crash, the write goes to the wrong place.

## Fix

The idiomatic fix is to either (a) do all reads/writes through the
borrow BEFORE any mutating call, or (b) use `getOrPut` to combine
the lookup and the insert into a single non-invalidating operation:

```zig
// (a) finish with the borrow first
const p = map.getPtr(key) orelse return error.NotFound;
p.* = newValue;
try map.put(other_key, other_value);

// (b) combine
const gop = try map.getOrPut(key);
if (!gop.found_existing) gop.value_ptr.* = default;
// ...do NOT call other mutating ops on `map` between here and the
// next use of `gop.value_ptr`/`gop.key_ptr`.
```

## Why the detector is precise

- Only `const` bindings (not `var`) — `var` allows reassignment that
  we don't track, which would force the rule to either skip those
  cases or risk FPs from rebinds.
- Mutate-method allowlist is narrow.  `clearAndFree`,
  `clearRetainingCapacity`, `ensureTotalCapacity`,
  `ensureUnusedCapacity` are deliberately omitted — they also
  invalidate, but the `ensure*` calls are nearly always the
  *pre-allocation idiom* (run BEFORE borrowing) and reporting them
  here would cost more in FPs than the real-bug yield.
- Receiver name must match exactly.  `a.getPtr(k); try b.put(...)`
  doesn't fire — `b` and `a` are different maps.
- Only the leading-identifier receiver shape is matched.  Chained
  receivers like `outer.inner.getPtr(k)` are out of scope for now —
  rare in practice and the matching logic would have to compare
  multi-token receiver chains exactly.
