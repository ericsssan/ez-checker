# free-without-null-then-check

A `<allocator>.destroy(<recv>.<field>);` or `.free(<recv>.<field>);`
in a NON-destructor fn, without a subsequent `<recv>.<field> = null;`
(or `= &.{}`, `= .empty`, or a fresh value).  The freed slot now
holds a dangling pointer.

The bug surfaces in two ways:

1. **Optional null-check passes a dangling non-null.**  Later code
   does `if (<recv>.<field>) |h| use(h);` — the optional check
   sees a non-null pointer (the dangling one) and proceeds to
   dereference it.  UAF in `use(h)`.

2. **`deinit` double-frees the dangling slot.**  The struct's own
   `deinit` walks its fields and frees them.  The previously-freed
   slot still holds the same dangling pointer → second free.

## Why this matters

This is the canonical "free, didn't invalidate" pattern in
long-lived structs that go through cycles of activate / use /
deactivate.  The freeing fn (named `markInactive`, `reset`,
`cancel`, `endOperation`, …) intends to release the resource and
leave the struct re-usable, but forgets that "leaving it re-usable"
requires reading the field as null/empty going forward.

5+ Bun PRs in two months touched this exact shape across different
modules — it's not a one-off; it's a recurring footgun that's
invisible until something pokes the optional check on the freed
slot.

## Canonical bug (oven-sh/bun#30148)

```zig
pub fn markInactive(self: *Self) void {
    self.gpa.destroy(self.handlers.?);
    // BUG: missing `self.handlers = null;`
}

// elsewhere:
pub fn check(self: *Self) JSValue {
    const handlers = self.handlers orelse return .js_undefined;
    if (handlers.mode != .server) ...;   // ← UAF: handlers points at freed mem
}
```

The `markInactive` fn frees the handlers pointer but leaves
`self.handlers` non-null.  The next call to `check` reads the
optional, sees a non-null value, and dereferences a dangling
pointer.

## Fix

Always pair the free with a slot reset:

```zig
pub fn markInactive(self: *Self) void {
    self.gpa.destroy(self.handlers.?);
    self.handlers = null;
}
```

For non-optional pointer-or-slice fields:

```zig
self.gpa.free(self.specifier);
self.specifier = &.{};       // empty slice — checks like `.len == 0`
                              // work and the deinit's blind free is a no-op.
```

## Why the detector is precise

- Skips destructor-named fns (`deinit`, `destroy`, `finalize`,
  `dispose`, `free`, `close`) — leaving stale pointers in a
  struct that's about to be discarded is fine.
- Skips comptime type-builder fns.
- Receiver pattern is narrow: `<recv>.<field>` (single identifier
  receiver, single identifier field).  Chained receivers
  (`self.parent.handlers`) are out of scope for the first cut.
- Reset suppression is broad: ANY assignment `<recv>.<field> = ...`
  later in the fn body (at any depth) is treated as a valid reset.
  This matches `= null`, `= &.{}`, `= .empty`, `= undefined`, or
  even reassignment to a fresh allocation.

## Related rules

- [`heap-use-after-free`](heap-use-after-free.md) — finds the USE
  site after a free; this rule fires at the FREE site so the bug
  is caught even before the use is written.
- [`free-then-try-realloc`](free-then-try-realloc.md) — specifically
  about a fallible re-allocation that may leave the slot dangling
  on error.
- [`overwrite-without-deinit`](overwrite-without-deinit.md) — the
  dual: overwriting a slot WITHOUT freeing the prior value.
