# move-out-without-restore

`var <X> = <OBJ>.<move-out>(...)` (or similar method that clears
`OBJ`'s internal state) followed by a fallible operation on `<X>`,
without a `defer <OBJ>.<restore>(<X>)` (or
`defer <OBJ>.* = ...`) registered between.  On the error path,
`<X>` is dropped with its partial allocation and `<OBJ>` is left
holding cleared/stale state — the caller's `OBJ.deinit()` later
either leaks the partial allocation or hits a stale pointer.

## Canonical bug (ziglang/zig#24452)

`Io.Writer.Allocating.toOwnedSlice*()` extracted its
ArrayList state, performed a fallible `list.toOwnedSlice(...)`,
and on error returned with the Allocating left empty.  Fix added
`defer a.setArrayList(list)`.

## Fix

Pair every move-out with a defer restore:

```zig
var list = a.toArrayList();
defer a.setArrayList(list);            // ← restores on both paths
const result = try list.toOwnedSlice(gpa);
return result;
```

## Why the detector is precise

- Move-out methods are a narrow allowlist:
  `toArrayList`, `toOwnedSlice`, `toOwnedSliceSentinel`,
  `detach`, `release`.
- Restore methods recognized: `setArrayList`, `fromArrayList`,
  `replaceWith`, `restore`, `attach`, `acquire`.  `defer <obj>.*
  = ...` (whole-struct reset) also counts.
- Fallible-op signal is `try <X>.<method>(...)` — a `try`
  immediately followed by `<X>` as the receiver.

## Limitations

- Doesn't track multi-hop aliasing of either `<X>` or `<OBJ>`.
- Doesn't recognize project-specific move/restore method names
  beyond the allowlist.
