# clobbered-by-struct-reset

A heap-owning field is assigned through a `*Self` parameter
(`this.<X> = <expr>;`), then `this.*` is reset with a struct literal
that does *not* include `.<X>`.  Zig fills the missing field with its
declared default — typically `null`, `0`, `""`, or `&.{}` — so the
prior heap pointer is overwritten and unreachable.  The type's
`deinit()` later checks the now-default field and frees nothing; the
allocation leaks every time the function runs.

The fix is to either include `.<X>` in the struct literal, drop the
struct-literal reset entirely (initialize the field at declaration
and assign individually), or skip the pre-assignment when it was
redundant.

## Example

Incorrect — `resolved_path` is dupeZ'd then immediately clobbered by
the struct literal, which doesn't carry the field forward:

    const resolved_path = bun.default_allocator.dupeZ(u8, src) catch …;
    this.resolved_path = resolved_path;
    this.* = PathWatcher{
        .path = path,
        .callback = callback,
        // ← .resolved_path missing — falls back to declared default `null`
        // and the dupeZ'd buffer is leaked
    };

Fix — carry the field forward in the literal (and drop the dead
pre-assignment):

    const resolved_path = bun.default_allocator.dupeZ(u8, src) catch …;
    this.* = PathWatcher{
        .path = path,
        .callback = callback,
        // …other fields…
        .resolved_path = resolved_path,
    };

## When this might be a false positive

- The pre-assignment was a no-op (the value was the default already
  and the author just wrote it for emphasis).  The struct-literal
  reset re-establishes the same default.  Rare but possible — drop
  the pre-assignment to clear the diagnostic.
- The field is intentionally being reset to its default to
  invalidate a stale handle (the prior write was through a different
  code path and the cleanup happens before this reset).  Add an
  explicit `bun.default_allocator.free(this.<X>);` immediately
  before the reset to make the ownership transfer visible.

## Related

- `heap-leak`: the type-level shape of "destructor doesn't free a
  heap field," a generalization of this per-call-site bug.
- `aliased-heap-dupe`: the converse leak — a bitwise copy that
  preserves rather than drops the heap pointer, leading to
  double-free instead of leak.
