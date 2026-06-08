# resize-result-discarded

**Severity:** error  
**Category:** out-of-bounds / allocator misuse  
**Tier:** 1 (token walk)

## What this checks

`_ = allocator.resize(slice, new_len)` — discarding the boolean return
value of `std.mem.Allocator.resize`.

`Allocator.resize` attempts an in-place resize of the existing allocation.
It returns:
- `true` — resize succeeded, the slice now covers `new_len` elements.
- `false` — in-place growth was impossible; the slice is **unchanged**.

When the caller discards the result with `_ = ...`, it doesn't know
whether the slice actually grew.  Writing beyond the original length
afterwards is out-of-bounds — OOB trap in Debug/Safe, heap corruption in
ReleaseFast.

## Example (fires)

```zig
// BUG: resize may return false; buf.len is still the old value
_ = allocator.resize(buf, buf.len + extra);
buf[buf.len - 1] = sentinel;  // OOB if resize returned false
```

## Fix

Use `realloc` to always get the new allocation (or error):

```zig
buf = try allocator.realloc(buf, buf.len + extra);
buf[buf.len - 1] = sentinel;  // safe: realloc succeeded
```

Or check the return value and fall back:

```zig
if (!allocator.resize(buf, buf.len + extra)) {
    buf = try allocator.realloc(buf, buf.len + extra);
}
buf[buf.len - 1] = sentinel;
```
