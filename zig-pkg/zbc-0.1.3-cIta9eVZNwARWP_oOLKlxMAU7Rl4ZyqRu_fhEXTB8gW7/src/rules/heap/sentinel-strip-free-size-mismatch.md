# sentinel-strip-free-size-mismatch

`<alloc>.free(<X>.ptr[0..<X>.len])` (or `<X>.ptr.?[0..<X>.len]`)
hand-rolls a `[]u8` slice from a many-item-pointer.  If `<X>` is
a sentinel-terminated slice (`[:0]const u8` produced by `dupeZ`,
`allocSentinel`, string literals like `"hello"`, etc.) the
underlying allocation is `len + 1` bytes — but the freed slice is
only `len` bytes.  The allocator's free-size check trips with
"Allocation size N+1 does not match free size N."

Even when `<X>` is NOT sentinel-terminated, the shape is
redundant: pass `<X>` directly to `free` instead of
re-constructing a slice from its `.ptr` and `.len`.

## Canonical bug (ghostty-org/ghostty#8886)

```zig
// src/main_c.zig — ghostty_string_free
pub export fn ghostty_string_free(str: ghostty_string_s) void {
    state.alloc.free(str.ptr.?[0..str.len]);
    // Trips: "Allocation size 41 bytes does not match free size 40"
    // because str was produced as [:0]const u8 with underlying
    // allocation len+1.
}
```

## Fix

Either pass the slice directly:

```zig
state.alloc.free(str);
```

or preserve the sentinel in the slice expression:

```zig
state.alloc.free(str.ptr.?[0..str.len :0]);
```

## Why the detector is precise

- Pattern is exact: `<alloc>.free(<X>.ptr[0..<X>.len])` or
  `<X>.ptr.?[0..<X>.len]`.  Both ident occurrences of `<X>`
  must match.
- `<alloc>.free(slice)` and `<alloc>.free(slice[0..N])` (without
  `.ptr`) are NOT flagged — only the `.ptr[...]` reconstruction
  shape, which is the canonical sentinel-strip footgun.
- `.?` (period_question_mark) is recognized as a single token.

## Limitations (deliberate)

- Doesn't track types — can't distinguish a benign use (the
  caller really did allocate a non-sentinel slice and just
  re-wrapped via `.ptr[0..len]`) from the sentinel bug.  Both
  are reported because the shape is redundant either way.
- Multi-segment receivers (`outer.inner.ptr[0..outer.inner.len]`)
  are out of scope — the rule requires single-identifier `<X>`.
