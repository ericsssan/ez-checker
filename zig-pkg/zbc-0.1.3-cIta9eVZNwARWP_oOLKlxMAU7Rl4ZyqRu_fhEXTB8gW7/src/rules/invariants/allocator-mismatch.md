# allocator-mismatch

A heap allocation is freed by a different allocator than the one
that produced it.  Under most Zig allocator implementations
(mimalloc, page-allocator, arena pools, custom GPAs) this is
undefined behavior — the freeing allocator's bookkeeping doesn't
know about the allocation, and may corrupt its own data structures
or silently leak.

## Example

Incorrect — `buf` is allocated by `mimalloc` but freed via
`default`:

    const buf = try mimalloc.alloc(u8, 32);
    // ...
    default.free(buf);                       // ← allocator mismatch

Fix — free with the same allocator that allocated:

    const buf = try mimalloc.alloc(u8, 32);
    // ...
    mimalloc.free(buf);

## When this might be a false positive

- The two named locals are aliased via `var a2 = a;` — they refer
  to the same underlying allocator but zbc compares by LocalId
  alone, so they look different.  Either use the same alias on
  both ends, or treat this as a hint to make the alias intent
  explicit.
- The allocator's `free` accepts arbitrary heap pointers (e.g.
  some test harnesses route all frees through a single sink).
  zbc has no way to know this; rework the call shape so a single
  named allocator is consistent end-to-end.

## Related

- `heap-double-free`: freeing the same pointer twice.
- `heap-use-after-free`: reading a freed pointer.
