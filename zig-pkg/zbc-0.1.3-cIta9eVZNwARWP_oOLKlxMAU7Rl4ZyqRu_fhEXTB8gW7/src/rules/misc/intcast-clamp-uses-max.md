# intcast-clamp-uses-max

**Severity:** error  
**Category:** misc / arithmetic  
**Tier:** 1 (token walk)

## What this checks

`@intCast(@max(expr, std.math.maxInt(T)))` — using `@max` to clamp a value
before narrowing it with `@intCast`.

The intent is to cap `expr` at `maxInt(T)` so that `@intCast` never sees an
out-of-range value.  But `@max(x, maxInt(T))` returns the *larger* of its two
operands:

- When `x <= maxInt(T)`: returns `maxInt(T)` — so every in-range value is
  forced to the maximum, which is semantically wrong.
- When `x > maxInt(T)`: returns `x`, and the subsequent `@intCast(x)` panics
  in debug or wraps silently in release — the exact scenario the clamp was
  meant to prevent.

## Example (fires)

```zig
// Intended to cap queueSize at 255 before storing as u8
new_credentials.options.queueSize = @intCast(@max(queueSize, std.math.maxInt(u8)));
//                                            ^^^^  should be @min
```

## Fix

Replace `@max` with `@min`:

```zig
new_credentials.options.queueSize = @intCast(@min(queueSize, std.math.maxInt(u8)));
```

`@min(x, 255)` returns `x` when `x <= 255` (preserving the value) and 255
when `x > 255` (capping it safely).

## Real-world instances

- oven-sh/bun#29813 — `@intCast(@max(queueSize, std.math.maxInt(u8)))` in
  connection credentials; any `queueSize > 255` caused a panic in debug builds
  and silent truncation in release.
