# f32-narrowing-int-to-float

**Severity:** error  
**Category:** misc / precision  
**Tier:** 1 (token walk)

## What this checks

`@as(f32, @floatFromInt(expr))` narrows an integer to `f32`.  `f32` only
represents integers exactly up to 2²⁴ (16,777,216).  For values above that,
`@floatFromInt` silently rounds to the nearest representable value.  When the
result is used in bounds checks, size arithmetic, or offset calculations, the
rounding invalidates the check — e.g., 33,554,433 rounds to 33,554,432,
passing a guard that should have caught it.

## Example (fires)

```zig
fn checkBounds(offset: usize, len: usize) bool {
    return @as(f32, @floatFromInt(offset)) < @as(f32, @floatFromInt(len));
    //     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^  silent rounding for large values
}
```

## Fix

Use `f64`, which represents integers exactly up to 2⁵³:

```zig
fn checkBounds(offset: usize, len: usize) bool {
    return @as(f64, @floatFromInt(offset)) < @as(f64, @floatFromInt(len));
}
```

If `f32` is genuinely required (e.g., GPU vertex buffers), clamp the integer
to the exact-integer range first:

```zig
const safe: u32 = @min(offset, 1 << 24);
const f: f32 = @floatFromInt(safe);
```

## Real-world instances

- oven-sh/bun#30134 — CSS parser typed-array offset bounds checks used
  `@as(f32, @floatFromInt(…))`, silently rounding large offsets and bypassing
  OOB guards.
