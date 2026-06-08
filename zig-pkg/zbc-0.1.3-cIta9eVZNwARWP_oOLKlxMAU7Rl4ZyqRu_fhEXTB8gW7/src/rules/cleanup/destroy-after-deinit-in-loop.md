# destroy-after-deinit-in-loop

A destructor (`deinit` / `finalize` / `destroy`) iterates over a list
of items, calling `<h>.deinit()` on each — but the loop body does
NOT also call `<allocator>.destroy(<h>)` (or `.free(<h>)`).  When
the list's element type is a heap-allocated pointer (the canonical
`std.ArrayListUnmanaged(*Handler)` shape where items are minted via
`allocator.create(Handler)`), the per-item `.deinit()` reclaims the
item's *fields* but not its *heap descriptor* — every list item
leaks its allocation.

The fix is to add an `<allocator>.destroy(<h>);` call right after
the per-item `<h>.deinit()`, matching the pairing that already
appears in the type's `errdefer` cleanup blocks of its
allocation-side methods.

## Example

Incorrect — handlers are `*ElementHandler` minted via
`bun.default_allocator.create(...)`, but the destructor only
deinit's them:

    pub fn deinit(this: *LOLHTMLContext) void {
        for (this.element_handlers.items) |handler| {
            handler.deinit();
            // ← missing: bun.default_allocator.destroy(handler);
        }
        this.element_handlers.deinit(bun.default_allocator);
    }

Fix:

    pub fn deinit(this: *LOLHTMLContext) void {
        for (this.element_handlers.items) |handler| {
            handler.deinit();
            bun.default_allocator.destroy(handler);
        }
        this.element_handlers.deinit(bun.default_allocator);
    }

## When this might be a false positive

- The list's element type is a value type (not a pointer), in
  which case `.deinit()` alone is correct.  zbc tightens this by
  requiring the field's declaration to contain `(*` or `[]*`
  (pointer-element list shape).  Lists of values won't fire.
- The item's `deinit()` itself calls `bun.destroy(self)` or
  similar self-destruction.  Rare and risky pattern; rewrite to
  pair the destroy at the call site.

## Related

- `heap-leak`: the type-level version where the destructor doesn't
  free `self` at all (whole-type leak).
- `interior-pointer-destroy`: the converse mistake where the loop
  captures an interior pointer (`|*p|`) and tries to destroy it.
