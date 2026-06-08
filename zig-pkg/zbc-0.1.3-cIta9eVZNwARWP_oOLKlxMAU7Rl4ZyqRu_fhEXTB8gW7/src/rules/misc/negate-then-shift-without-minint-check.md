# negate-then-shift-without-minint-check

**Severity:** error  
**Category:** integer overflow / UB  
**Tier:** 1 (token walk)

## What this checks

A signed integer is negated (`-value`) and then left-shifted (`<< N`) without
a guard that handles the case where `value == std.math.minInt(@TypeOf(value))`.

In two's complement arithmetic, `std.math.minInt(i32)` (−2,147,483,648) has
no positive representation: `-minInt(i32)` overflows back to `minInt(i32)`.
Left-shifting the already-wrong result produces garbage output.  In Zig's
Debug and ReleaseSafe builds this traps at runtime; in **ReleaseFast** it
silently wraps.

## Example (fires)

```zig
// VLQ / zigzag encoding — BUG when value == std.math.minInt(i32)
fn encodeVlq(value: i32) u32 {
    return if (value >= 0)
        @intCast(value << 1)
    else
        @intCast((-value << 1) | 1);  // ← -value overflows for minInt
}
```

## Fix

Use `@bitCast` to reinterpret the bits without a signed negation:

```zig
fn encodeVlq(value: i32) u32 {
    // Zigzag: non-negative → even, negative → odd, no signed overflow.
    return @bitCast((value << 1) ^ (value >> 31));
}
```

Or explicitly guard the minInt case:

```zig
fn encodeVlq(value: i32) u32 {
    if (value == std.math.minInt(i32)) return std.math.maxInt(u32); // sentinel
    return if (value >= 0)
        @intCast(value << 1)
    else
        @intCast((-value << 1) | 1);
}
```

## Real-world instance

- oven-sh/bun#10782 — `sourcemap.zig` `encodeVLQ`: when
  `value == std.math.minInt(i32)`, `-value` overflowed and the subsequent
  `<< 1` produced a wrong source-map offset, corrupting the output.
