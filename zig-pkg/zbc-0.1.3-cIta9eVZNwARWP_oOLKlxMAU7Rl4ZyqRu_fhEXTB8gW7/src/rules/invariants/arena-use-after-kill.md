# arena-use-after-kill

Reading a value whose storage lives inside an arena, after that
arena has been `.deinit()`'d.  Every borrow from the arena — and
every value initialized through `arena.allocator()` — becomes
invalid the moment `deinit` runs.

## Example

Incorrect — `log` is initialized from `arena.allocator()`, so its
backing storage dies with the arena:

    var arena = std.heap.ArenaAllocator.init(gpa);
    const log = Log.init(arena.allocator());
    arena.deinit();
    return throwValue(log.toJS(global, ...));   // ← use after kill

Fix — move the throw before the deinit, or use a longer-lived
allocator:

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const log = Log.init(arena.allocator());
    return throwValue(log.toJS(global, ...));   // arena still live

## When this might be a false positive

- The borrow conceptually outlives the arena because it was COPIED
  out (e.g. duped into a longer-lived allocator).  zbc does not
  track ownership transfer through `dupe` calls; suppress the line
  with `// zbc-disable-line:arena-use-after-kill` if the copy
  semantics are real.
- The arena is itself heap-allocated and ownership of the *whole*
  arena was transferred (assigned into a struct field that
  outlives the function).  zbc's `pointer_write` semantic
  preserves the arena origin through field writes, but transfer
  via an untracked call may need a suppression.

## Related

- `arena-escape`: returning a borrow PAST the arena's death —
  a specific case where the borrow leaks via the return value.
- `heap-use-after-free`: same shape, but the resource is a single
  heap allocation, not an arena.
