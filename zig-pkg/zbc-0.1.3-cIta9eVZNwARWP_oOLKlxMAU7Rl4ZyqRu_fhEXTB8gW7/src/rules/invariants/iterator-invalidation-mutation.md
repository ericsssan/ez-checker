# iterator-invalidation-mutation

`for (<list>.items) |...| { <list>.<mutate>(...); }` — the loop body
calls a method on the SAME list that reallocates or shifts its backing
storage.  The loop iterates over a snapshot of `.items` that may now
point at freed memory (after `append`/`resize`) or at shifted elements
(after `insert`/`remove`/`swapRemove`), producing use-after-free or
skipped-element bugs.

## Example

Incorrect:

    for (list.items) |item| {
        if (item.active) try list.append(allocator, item.clone());  // ← realloc!
    }

Fix — iterate over a snapshot or use an index loop:

    const n = list.items.len;        // snapshot length before mutations
    for (list.items[0..n]) |item| {
        if (item.active) try list.append(allocator, item.clone());
    }

## What is flagged

Mutations that reallocate or reorder: `append`, `appendSlice`,
`appendNTimes`, `insert`, `insertSlice`, `addOne`, `addManyAsSlice`,
`addManyAsArray`, `resize`, `clearAndFree`, `clearRetainingCapacity`,
`deinit`, `swapRemove`, `orderedRemove`, `pop`, `popOrNull`,
`replaceRange`, `shrinkAndFree`, `shrinkRetainingCapacity`.

`appendAssumeCapacity` and `appendSliceAssumeCapacity` are NOT flagged —
they write within existing capacity and do not move the backing buffer.

## Related

- **arraylist-items-slice** — fires on `const X = list.items;` followed
  by a mutation and then use of `X`, the explicit-slice-borrow variant.
- **hashmap-iter-mutation** — the HashMap iterator variant.
