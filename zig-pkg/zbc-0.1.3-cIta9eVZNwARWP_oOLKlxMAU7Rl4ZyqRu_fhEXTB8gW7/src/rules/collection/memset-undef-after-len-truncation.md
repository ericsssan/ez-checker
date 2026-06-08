# memset-undef-after-len-truncation

`<X>.<field>.len = NEW;` immediately followed (in the same scope)
by `@memset(<X>.<field>..., undefined);` — the memset slices the
ALREADY-TRUNCATED items, so the range is empty and the memset is a
no-op.  The freed-but-retained capacity keeps its old bytes,
defeating Zig's `undefined` use-after-shrink safety detection.

## Why this matters

Zig's standard library uses `@memset(..., undefined)` to poison
freed-but-retained-capacity bytes — so that any subsequent
out-of-bounds read of the shrunk array sees `0xaa` patterns under
`ReleaseSafe`, helping catch use-after-shrink bugs at runtime.

When the `len = NEW` truncation happens BEFORE the `@memset`, the
memset is operating on `self.items[NEW..]` — a slice of
`self.items` (which now has length NEW) starting at index NEW.
That slice is empty.  The memset writes zero bytes.  The old
capacity keeps its real-data bytes.

The fix is mechanical: swap the order.

## Canonical bug (ziglang/zig#25810, #25832)

```zig
pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
    self.items.len = new_len;                         // truncate first
    @memset(self.items[new_len..], undefined);         // ← empty slice → no-op
}

pub fn clearRetainingCapacity(self: *Self) void {
    self.items.len = 0;                                // truncate first
    @memset(self.items, undefined);                    // ← empty slice → no-op
}
```

These shipped in `std.ArrayListAligned` and were fixed in
ziglang/zig#25810 (`Aligned`) then ziglang/zig#25832 (the same
fix forgotten for `AlignedManaged`).

## Fix

Swap the order — memset the to-be-discarded tail FIRST, then
truncate:

```zig
pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
    @memset(self.items[new_len..], undefined);   // poison while slice is still valid
    self.items.len = new_len;
}

pub fn clearRetainingCapacity(self: *Self) void {
    @memset(self.items, undefined);              // poison full items
    self.items.len = 0;
}
```

## Why the detector is precise

- Pattern is exact: `<X>.<field>.len = ...;` followed (in the same
  scope) by `@memset(<X>.<field>...)`.  Both sides must use the
  SAME `<X>.<field>` token pair.
- Skips comptime type-builder fns.
- If the memset references a SAVED length captured before
  truncation (`const old = self.items.len; self.items.len = new;
  @memset(self.items.ptr[new..old], undefined);`), the rule
  doesn't fire — the memset target starts with `self.items.ptr`,
  not `self.items`, so the prefix-match doesn't trigger.

Limitations:
- Only matches the canonical `<X>.<field>` shape — multi-segment
  paths (`self.inner.items.len = ...`) are out of scope.
- Doesn't catch the rare pattern where the truncation and memset
  are in different fns called from a third fn.
