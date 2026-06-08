# union-payload-ptr-after-variant-change

A pointer is taken into the active-variant payload of a tagged union, and then
the union is reassigned to a different variant.  After the reassignment the
storage the pointer referenced belongs to the new variant — the old pointer is
dangling and any read or write through it is a use-after-free.

## Why this matters

A tagged union's payload variants share a single memory region.  When the
active variant changes (e.g. `this.state = .{ .err = … }`), the compiler is
free to immediately begin using that region for the new variant's payload.  A
pointer taken before the change still points at the same bytes, but those bytes
now belong to a completely different type.  Reading through the old pointer
produces undefined behaviour; writing through it silently corrupts the new
variant's payload.

The bug is easy to miss because ownership of the storage is implicit.  In heap
code a `free` makes invalidation obvious; in a union there is no explicit
"free" — the variant change is the only signal, and it can occur many lines
after the pointer was taken.

## Example

```zig
// BUG (oven-sh/bun#29977)
const pending = &this.state.pending;   // pointer into .pending payload
// …intervening code…
this.state = .err;                     // active variant switched — .pending
                                       // storage is now repurposed for .err
if (pending.dev_server) |server| {     // UAF: reads repurposed memory
    server.triggerHotReload();
}
```

### Fix

Copy the needed fields into locals **before** reassigning the union:

```zig
// FIXED
const dev_server = pending.dev_server; // copy before variant change
this.state = .err;
if (dev_server) |server| {             // safe: reads from the local copy
    server.triggerHotReload();
}
```

## When this might be a false positive

- **Wrapped re-assignment with same tag**: If `recv.field` is reassigned to the
  same variant (e.g. `this.state = .{ .pending = updated_pending }`), the
  payload region is still in use for the same type and the pointer remains
  valid.  The detector fires conservatively in this case because it cannot
  determine the new variant from a purely syntactic scan.  Hoist the needed
  fields into locals to suppress the diagnostic.

- **Pointer not actually used**: If the identifier `ptr` appears after the
  variant change but in unreachable code or inside a nested function, the
  diagnostic may be spurious.  The detector uses a scope-bounded scan
  (`findIdentInScope`) that stops at the first `}` that closes the current
  scope, which limits but does not eliminate this possibility.

- **Struct fields named identically to union variants**: A deeply nested
  non-union struct whose outermost field shares a name with a union variant
  could match the `recv.field1 = …` pattern.  In practice this is rare; the
  fix (copy before reassign) is correct regardless and has zero runtime cost.
