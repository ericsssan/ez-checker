# hashmap-iter-mutation

Modifying a `HashMap` while iterating over it (via `iterator()`,
`keyIterator()`, or `valueIterator()`) invalidates the iterator's
internal cursor.  Subsequent `iter.next()` calls have undefined
behaviour — on Zig's open-addressing hash table the cursor may revisit
the same slot, skip slots, or run off the end.

## Example

Incorrect:

    var it = map.iterator();
    while (it.next()) |entry| {
        if (shouldRemove(entry.key_ptr.*)) {
            map.remove(entry.key_ptr.*);   // ← invalidates `it`
        }
    }

Fix — collect keys to remove first, then remove after iteration:

    var to_remove: std.ArrayListUnmanaged(K) = .empty;
    defer to_remove.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |entry| {
        if (shouldRemove(entry.key_ptr.*))
            try to_remove.append(allocator, entry.key_ptr.*);
    }
    for (to_remove.items) |k| _ = map.remove(k);

## Related

- **iterator-invalidation-mutation** — the ArrayList / `for (list.items)`
  variant of this pattern.
- **hashmap-getptr-rehash** — using a borrowed pointer after a rehashing
  mutation invalidates the pointer.
