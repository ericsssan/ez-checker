# intfromfloat-without-clamp

**Severity:** error  
**Category:** integer overflow / UB  
**Tier:** 1 (token walk)

## What this checks

`@intFromFloat(expr)` where the argument expression does not contain a
`@min`, `@max`, `@round`, `@floor`, `@ceil`, `@trunc`, or `std.math.clamp`
guard.

`@intFromFloat` panics in Debug/ReleaseSafe when the float is:
- greater than the target integer's max value
- less than the target integer's min value
- `+Inf` / `-Inf`
- `NaN`

In ReleaseFast these cases produce silent undefined behaviour.  JS timer
values, peer-advertised timeouts, and GC-scheduler delays are all floats
that can legitimately be very large (or infinite), so they must be clamped
before the cast.

## Example (fires)

```zig
// BUG: modf.ipart can be +Inf when seconds is +Inf
const modf = std.math.modf(seconds);
interval.sec += @intFromFloat(modf.ipart);
```

```zig
// BUG: float from JS could exceed i64 range
const int: i64 = @intFromFloat(float_from_js);
```

## Fix

Clamp the float before conversion:

```zig
const clamped = @min(@max(seconds, 0.0), @as(f64, std.math.maxInt(i32)));
interval.sec += @intFromFloat(clamped);
```

Or use `std.math.lossyCast` which handles out-of-range and NaN gracefully:

```zig
interval.sec += std.math.lossyCast(i64, modf.ipart);
```

## Real-world instances

- oven-sh/bun#28364 — `Timer`: `modf.ipart` of a JS timer value could be
  `+Inf`; `@intFromFloat` panicked.
- oven-sh/bun#29328 — GC scheduler passed a float that exceeded `i64`
  range to `@intFromFloat`, causing a panic.
