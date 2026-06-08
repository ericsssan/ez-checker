# field-self-assign-with-cast

`self.field = @as(T, @intCast(self.field))` — field assigned to itself through a cast. The assignment is a no-op: the same value is read, cast to the same type, and written back. This is almost always a copy-paste error where the programmer intended to use a freshly-computed local variable on the RHS.

## What the rule checks

The rule fires on three forms where the LHS and the innermost RHS reference the same receiver and field:

- **Form A**: `recv.field = @as(T, @intCast(recv.field))` — wrapped @as + @intCast
- **Form B**: `recv.field = @intCast(recv.field)` — bare @intCast
- **Form C**: `recv.field = @as(T, recv.field)` — wrapped @as only

The receiver and field names are compared textually. If they differ (different receiver or different field), the rule does not fire.

## Why it matters

A field self-assignment through a cast performs no work. The programmer wrote what looks like a meaningful update but the field value is unchanged after the line executes. For positional state (seek cursors, offsets, lengths), this means the intended advance never happens, leaving the object in its previous state indefinitely.

Because the code compiles and runs without errors (the types match), the bug is silent. It only manifests as wrong behavior at a higher level — reads at unexpected positions, infinite loops, or data that is always zero-offset.

## Real-world instance

**oven-sh/bun#25905** (BufferReadStream.seek): `this.pos = @as(usize, @intCast(this.pos))` was written instead of `this.pos = @as(usize, @intCast(new_pos))`. The local variable `new_pos` held the computed seek target but was never assigned to the field. Every call to `seek()` left the stream at the same position, making all subsequent reads return the same data.

## Fix

```zig
// Instead of:
this.pos = @as(usize, @intCast(this.pos));  // no-op

// Use the computed value:
this.pos = @as(usize, @intCast(new_pos));
```
