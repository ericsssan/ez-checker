# opt-capture-ptr-after-field-clear

Inside an `if (<recv>.<field>) |*<cap>|` block, a local pointer `<ptr>`
is derived from `<cap>` (the mutable reference to the optional payload).
A subsequent **inline assignment** `<recv>.<field> = …` clears or
replaces the optional — destroying the storage `<ptr>` was pointing
into.  Any use of `<ptr>` after the assignment is a use-after-free.

The callee variant of this bug — where a method call clears the field
instead of an inline assignment — is caught by the CFG-level
`heap-use-after-free` rule (when the callee's `may_free_fields` summary
is available).  This rule complements it by covering the inline-clear
shape without requiring summary inference.

## Example

Incorrect — `clips` is derived from `clips_and_vp` (the optional
payload pointer), then the optional is cleared, then `clips` is used:

    if (this.clips) |*clips_and_vp| {
        var clips = &clips_and_vp.*[0];   // interior pointer into payload
        this.clips = null;                 // payload freed / invalidated
        clips.deinit(alloc);              // UAF: clips still points into freed payload
    }

Fix — use `clips_and_vp` directly before clearing the field, or capture
the value before clearing:

    if (this.clips) |*clips_and_vp| {
        var clips_val = clips_and_vp.*[0];  // copy, not pointer
        this.clips = null;
        clips_val.deinit(alloc);            // safe: working on a copy
    }

## When this might be a false positive

- `<recv>.<field>` is reassigned to a NEW value that keeps the same
  backing allocation (e.g. `this.buf = try grow(this.buf)`).  In that
  case `<ptr>` may still be valid.  Suppress with a comment or
  restructure so the pointer use precedes the reassignment.
- The pointer arithmetic is intentionally transitioning from the old
  allocation to the new one and `<ptr>` captures the old pointer before
  the reassignment.  Uncommon; the usual fix is to hoist the dereference.

## Related

- `heap-use-after-free`: CFG-level rule for the callee-clear variant.
- `overwrite-without-deinit`: dual — overwriting a field without
  calling `deinit` on the old value (wrong direction of cleanup).
- `free-without-null-then-check`: freeing a field without nulling it,
  so the dangling pointer is later checked and passed.
