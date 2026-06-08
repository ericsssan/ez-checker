# int-sum-overflow-in-bounds-cmp

**Severity:** error  
**Category:** integer overflow / bounds check bypass  
**Tier:** 1 (token walk)

## What this checks

A bounds check of the form `data.len < (a + b)` (or `(a + b) > data.len`)
where the sum `a + b` may be computed in a narrower integer type (e.g. `u32`)
and wrap to a small value before being compared against the `usize` length.

In Zig, integer arithmetic is strictly typed.  If `a` and `b` are `u32`,
`a + b` overflows at 4 GiB and wraps back toward zero.  A wrapped sum
compares smaller than `data.len`, so the guard evaluates `false` even
though the actual combined extent far exceeds the buffer — the check is
silently bypassed.

## Example (fires)

```zig
// BUG: header_length and message_len are u32
//      when message_len = 0xFFFFFFFB, header_length + message_len wraps to 0
if (data.len < (header_length + message_len)) {
    return error.TruncatedInput;
}
// Guard bypassed → data[header_length..][0..message_len] reads ~4 GiB
const message = data[header_length..][0..message_len];
```

## Fix

Subtract to keep the arithmetic in `usize`:

```zig
if (data.len - header_length < message_len) return error.TruncatedInput;
const message = data[header_length..][0..message_len];
```

Or explicitly widen the summands:

```zig
if (data.len < @as(usize, header_length) + @as(usize, message_len)) {
    return error.TruncatedInput;
}
```

## Real-world instance

- oven-sh/bun#30157 — IPC message decoder:
  `if (data.len < (header_length + message_len))` where both were `u32`;
  `message_len = 0xFFFFFFFB` caused the sum to wrap to `0`, bypassing the
  bounds check and allowing a ~4 GiB out-of-bounds slice to be returned.
