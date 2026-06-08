# return-borrowed-payload

A `return switch (<expr>) { ... };` with **sibling-arm asymmetry**:
one arm returns the captured payload bare (`.<Tag> => |v| v`)
while a sibling arm clones / allocates a fresh value
(`alloc.dupe(...)`, `try v.clone(alloc)`, etc.).  The bare arm
returns a slice/pointer borrowed from the caller's input, which
may be freed while the return value is still in use.

## Why this matters

The sibling-arm asymmetry is the strongest signal that the bare
arm is an oversight.  When one arm goes to the trouble of
`alloc.dupe(...)` the author clearly intends the returned value
to be owned by `alloc`; the adjacent bare-return arm gives back
a borrowed view from the caller's input instead.

Lifetime symptoms: the caller's input gets freed (often via a
local arena or stack buffer), then the held return value
dereferences a dangling pointer.  Hard to spot in review because
the borrow happens *inside* a switch arm and looks just like
"unwrap the variant."

## Canonical bug (ghostty-org/ghostty#8358 / #7711)

```zig
return switch (command) {
    .direct => |v| v,                                   // ← UAF: borrows from `command`
    .shell  => |v| (try command.clone(alloc)).shell,   // ← properly owned
};
```

If the caller frees `command` after this returns, the `.direct`
value's payload points at freed memory.

## Fix

Clone the borrowed payload too:

```zig
return switch (command) {
    .direct => |v| try alloc.dupe(u8, v),
    .shell  => |v| (try command.clone(alloc)).shell,
};
```

## Why the detector is precise

- The rule's main precision lever is **sibling-arm asymmetry**.
  If ALL arms return their payload bare, no fire (no signal
  that the author intended ownership transfer).  If at least
  one arm clones AND another returns bare, fire on the bare arm.
- Bare-return detection is strict: the arm body must be JUST
  `<capture>` (optionally followed by `,`).  Any further
  expression (`.<field>`, `(...)`) means there's processing
  beyond a bare borrow.
- Clone detection: `.<method>(` where method ∈ {`dupe`, `dupeZ`,
  `alloc`, `allocSentinel`, `create`, `clone`, `cloneWith`,
  `allocPrint`, `allocPrintZ`, `toOwnedSlice`,
  `toOwnedSliceSentinel`}.
- Only applies to `return switch (...) { ... };` — not bare
  switches whose result is captured into a local first.  The
  return-shape is what makes the borrowed value escape.
- Arms without a capture (`.Tag => doStuff()`) are skipped —
  there's no obvious bare-borrow shape to flag.
