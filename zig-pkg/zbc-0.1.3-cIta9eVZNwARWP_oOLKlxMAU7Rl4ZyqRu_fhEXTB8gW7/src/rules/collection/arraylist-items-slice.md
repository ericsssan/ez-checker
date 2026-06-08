# arraylist-items-slice

A `const <X> = <list>.items;` borrows a slice over the list's
heap-backed storage.  A subsequent receiver-matched
`<list>.<mutate>(...)` call — where `mutate ∈ {append, appendSlice,
appendNTimes, insert, insertSlice, addOne, addManyAsSlice,
addManyAsArray, resize, clearAndFree, deinit}` — may reallocate the
backing storage and invalidate `<X>.ptr`.  A later read or write
through `<X>` is a use-after-free against list storage.

Sibling of [hashmap-getptr-rehash](hashmap-getptr-rehash.md) — same
borrow-then-mutate family, this time against `std.ArrayList`-shaped
APIs (`ArrayList`, `ArrayListUnmanaged`, `BoundedArray`, anything
exposing `.items` + an `.append`-style API).

## Why this matters

Zig's `ArrayList` documents that `.items` is a view over the
current backing storage.  Any capacity-modifying call — anything
that may grow the list — may reallocate and free the old buffer.
Holding `const items = list.items;` across such a call is exactly
the canonical use-after-free.

The failure mode is intermittent: only fires when the `append`
happens to hit a resize threshold (which depends on capacity,
initial size, and growth factor).  This is the same family of bug
as the HashMap getPtr rehash — both are pointer-stability footguns
documented in std but compiler-invisible.

## Canonical bug

```zig
const items = list.items;                  // ← borrow
try list.append(allocator, x);              // ← may reallocate → invalidates `items`
items[0] = y;                               // ← UAF write
```

If the `append` triggered a resize, `items.ptr` now points at
freed heap.  The `items[0] = y` write lands in the freed block
(possibly clobbering an unrelated allocation, or segfaulting under
hardened allocators).

## Fix

Either finish reads/writes through the borrow BEFORE the mutating
call, or re-fetch `.items` after:

```zig
// (a) finish first
const items = list.items;
items[0] = y;
try list.append(allocator, x);

// (b) re-fetch
try list.append(allocator, x);
const items = list.items;   // fresh view
items[0] = y;

// (c) pre-reserve capacity then use appendAssumeCapacity
try list.ensureUnusedCapacity(allocator, 1);
const items = list.items;
items[0] = y;
list.appendAssumeCapacity(x);   // no realloc by contract
```

## Why the detector is precise

- Only `const X = <recv>.items;` (exact shape, single-identifier
  receiver, no chaining).  Sub-slice (`.items[lo..hi]`) and
  element-pointer (`&.items[i]`) borrows are out of scope for the
  first cut — they have their own AST complexities and bugs there
  are less common.
- Only `const` bindings — `var` introduces reassignment we don't
  track.
- Mutate-method allowlist is narrow.  `*AssumeCapacity` variants
  are deliberately excluded: by contract they don't reallocate.
  `ensureTotalCapacity*` / `ensureUnusedCapacity` are excluded
  because they're the pre-allocation idiom (called BEFORE borrow
  in the canonical pattern).  `swapRemove` / `orderedRemove` /
  `pop` are excluded — they shrink without reallocating, so the
  slice's `.ptr` stays valid.
- Receiver name must match exactly — `a.items; try b.append(...)`
  doesn't fire.
- The mutate must be at the same lexical block depth as the
  binding (no nested catch/if/loop bodies), and not inside a
  `defer`/`errdefer` (deferred actions don't fire at the lexical
  point).
- Use-lookup is bounded by the binding's enclosing scope — a
  shadowed `items` in a sibling loop capture doesn't count.
