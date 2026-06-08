# ptr-slice-without-bounds-check

**Severity:** error  
**Category:** out-of-bounds / buffer overread  
**Tier:** 1 (token walk)

## What this checks

`.ptr[0..N]` where N is 2, 3, or 4 — creating a fixed-size slice from a
raw pointer into a slice without the slice's bounds protection.

Zig slice indexing `slice[0..N]` is bounds-checked at runtime.  Writing
`slice.ptr[0..N]` strips the length and bypasses that check.  If the source
slice has fewer than N bytes (e.g., at end of input), this reads `N - len`
bytes past the allocation — silent memory disclosure in ReleaseFast.

The pattern is common in multibyte character decoders that need a
fixed-size window (e.g., 4 bytes for UTF-8) but forget that the last
codepoint at end-of-input may be truncated.

## Example (fires)

```zig
// BUG: bytes may have < 4 bytes remaining at end of input
fn next(self: *Iterator) u21 {
    const window: *const [4]u8 = self.bytes.ptr[0..4];
    return decodeCodepoint(window);
}
```

## Fix

Check length before taking the window:

```zig
fn next(self: *Iterator) !u21 {
    if (self.bytes.len < 4) return error.Truncated;
    const window: *const [4]u8 = self.bytes.ptr[0..4];
    return decodeCodepoint(window);
}
```

Or use `std.mem.readInt` / `std.unicode.utf8Decode` which handle
short inputs safely.

## Real-world instance

- oven-sh/bun#29999 — `strings/CodepointIterator.next`:
  `self.bytes.ptr[0..4]` was called without checking that
  `self.bytes.len >= 4` at the end of input, reading up to 3 bytes
  beyond the slice's backing allocation.
