# realloc-byte-count

A call to `<allocator>.realloc(slice, <expr> * @sizeOf(T))` — the
new-length argument multiplies by `@sizeOf(T)` as if it were a byte
count.  Zig's `Allocator.realloc` (and `alloc` / `allocSentinel`)
take an **element** count, not a byte count: the runtime computes
`new_count * @sizeOf(SliceElement)` internally to reach the byte
size.  The extra `* @sizeOf(T)` over-allocates by a factor of
`@sizeOf(T)` on every call.

mimalloc tolerates the wrong `old_size` so a wrong second arg
doesn't crash — it just silently holds `@sizeOf(T)×` the memory
the caller intended.

The fix is to drop the `* @sizeOf(T)`:

    allocator.realloc(slice, new_count)

If the slice is genuinely `[]u8` and you really do want byte-sized
allocations, name the new-byte-count locally so the intent is
unambiguous (`const new_bytes = new_count * @sizeOf(T);`) — the
rule's exact pattern match `<expr> * @sizeOf(<ident>)` will then
be replaced by a named binding and stop firing.

## Example

Incorrect — over-allocates by `@sizeOf(Selector)×` on every grow
of a spilled `SmallList(Selector, _)`:

    break :new_alloc bun.handleOom(
        allocator.realloc(ptr[0..length], new_cap * @sizeOf(T))
    ).ptr;

Fix:

    break :new_alloc bun.handleOom(
        allocator.realloc(ptr[0..cap], new_cap)
    ).ptr;

## When this might be a false positive

- The slice is `[]u8` and you really are sizing it in bytes (e.g.
  `allocator.realloc(buf, n * @sizeOf(SomeType))` where buf is a
  byte buffer and you want `n` slots for SomeType inside it).
  Rename the byte count into a `const total_bytes = …;` binding so
  the realloc call reads `realloc(buf, total_bytes)` and stop
  triggering the substring pattern.
- The call is `alloc`/`allocSentinel` with an explicit `u8` element
  type (`allocator.alloc(u8, n * @sizeOf(T))`).  Same shape, also
  legitimate when allocating a byte staging buffer.  zbc currently
  only flags `realloc`, where the same expression with a typed
  slice is unambiguously wrong.

## Related

- `allocator-mismatch`: a different allocator-API misuse — freeing
  with a different allocator than the one that allocated.
