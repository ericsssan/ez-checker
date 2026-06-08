# aliased-heap-dupe

A "dupe" function returns `T` by value through a bitwise copy of
`*const T` (`var dup = this.*; return dup;`).  Type `T` has a
heap-owning field signalled by an `<X>_allocated: bool` flag (the
canonical Zig idiom for conditional ownership: a slice or pointer
that lives on the heap *sometimes*, gated by a sibling bool), but
the dupe doesn't take an independent owning copy of `<X>` nor clear
the flag on the dupe.

After the dupe both the original and the returned value hold the
*same* heap pointer with `<X>_allocated == true`.  Whichever side's
destructor runs first frees the pointer; the other side now has a
dangling reference with the flag still set, leading to a
use-after-free on the next read of `<X>` and a double-free on the
second `deinit`.

The fix is to either re-allocate `<X>` on the dupe or clear the
flag on whichever side is about to drop ownership.

## Example

Incorrect — `duped` aliases `this.content_type` and both have
`content_type_allocated == true`:

    pub fn dupeWithContentType(this: *const Blob, _: bool) Blob {
        if (this.store != null) this.store.?.ref();
        var duped = this.*;
        duped.setNotHeapAllocated();
        // ← missing: deep-copy content_type, or clear flag
        return duped;
    }

Fix (deep-copy the owned field):

    pub fn dupeWithContentType(this: *const Blob, _: bool) Blob {
        if (this.store != null) this.store.?.ref();
        var duped = this.*;
        duped.setNotHeapAllocated();
        if (duped.content_type_allocated) {
            duped.content_type = bun.handleOom(bun.default_allocator.dupe(u8, this.content_type));
        }
        return duped;
    }

## When this might be a false positive

- The dupe is paired with a corresponding ownership-transfer call
  on the source — e.g. `this.transfer()` that clears `<X>_allocated`
  on the original.  zbc can't follow the helper.  Rewrite the
  transfer to do the clear inline, or rename the function so it
  doesn't look like a dupe.
- The `<X>_allocated` flag is misleading — `<X>` is never freed in
  any destructor of `T`, the flag is just informational.  Rename
  the flag to remove the `_allocated` suffix.

## Related

- `heap-use-after-free`: the typical first symptom — one side
  frees `<X>` while the other side still holds a flagged pointer.
- `heap-double-free`: the second symptom, fired when both sides'
  destructors run.
