# iterator-invalidation-mutation

`for (<list>.items) |...| { ... <list>.<mutate>(...); ... }` —
the loop iterates over a snapshot of `.items` while the body
calls a method on the SAME list that reallocates or reorders
the backing storage.  The loop's slice borrow may dangle
(append/resize realloc) or skip/double-visit elements
(insert/swapRemove/remove); hashmap iterators get rehashed by
put/remove.

## Shape

```zig
for (list.items) |x| {
    if (cond(x)) try list.append(...);  // ← INVALIDATES the slice
}
```

After `append`, if the new length exceeds capacity, the list
reallocates: `list.items.ptr` now points at freed memory while
the loop is still advancing through the OLD `.items.ptr`.  UAF
or misread on the next iteration.

For `insert`/`remove`/`swapRemove`, the storage isn't freed but
elements shift; the loop may skip the moved element or visit a
moved-in element twice.

## Mutator allowlist

ArrayList / ArrayListUnmanaged:
- `append` / `appendSlice` / `appendNTimes`
- `appendAssumeCapacity` / `appendSliceAssumeCapacity` —
  no realloc, but `insert` shifts; still wrong inside the loop
- `insert` / `insertSlice`
- `addOne` / `addManyAsSlice` / `addManyAsArray`
- `resize` / `clearAndFree` / `clearRetainingCapacity` / `deinit`
- `swapRemove` / `orderedRemove`
- `pop` / `popOrNull`
- `replaceRange`
- `shrinkAndFree` / `shrinkRetainingCapacity`

HashMap / HashMapUnmanaged (rehash invalidates iterators):
- `put` / `putAssumeCapacity` / `putAssumeCapacityNoClobber` /
  `putNoClobber`
- `remove` / `fetchRemove`
- `getOrPut` / `getOrPutValue`

## Detection

Per-fn token walk:
1. Find `for (<ident>.items)` / `for (<ident>.values)` /
   `for (<ident>.keys)` — single-input loops only (multi-input
   `for (a, 0..)` doesn't match, conservatively skipped).
2. The receiver must be a SINGLE identifier — multi-segment
   receivers (`this.foo.items`) are skipped to avoid loop-
   capture shadowing FPs (`for (this.ltr.items) |*ltr|` — the
   body's `ltr` is the LOOP CAPTURE, not the field).
3. Inside the loop body, search for `<recv>.<mutator>(` at any
   depth.  Skip nested fn declarations.
4. Fire on the mutate-call site with a note pointing at the
   for-header.

## False positives & coverage

Conservative on purpose:
- Multi-segment receivers (`this.list.items`) skipped — common
  shape but ambiguous with capture shadowing.
- Multi-input loops (`for (list.items, 0..)`) skipped — the
  pattern is usually safer (index-based) and detection would
  need scrutinee splitting.
- Method-call projectors (`map.values()` vs `map.values`) skipped
  — call form yields a freshly-built array, not a borrow.

## Sibling rules

- [[arraylist-items-slice]] — explicit `const X = list.items;`
  binding followed by `list.<mutate>()` and a later use of X.
  This rule fires on the loop SHAPE; the binding form fires on
  the explicit borrow.
- [[hashmap-getptr-rehash]] — `getPtr` / `getOrPut.value_ptr`
  invalidated by a subsequent capacity-modifying call.

## Real-world

Common Zig footgun.  Zig stdlib docs explicitly warn that
ArrayList's `items` slice and HashMap iterators are
invalidated by capacity-modifying operations.
