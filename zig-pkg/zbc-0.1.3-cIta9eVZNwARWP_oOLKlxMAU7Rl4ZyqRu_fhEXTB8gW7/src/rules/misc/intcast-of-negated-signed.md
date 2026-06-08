# intcast-of-negated-signed

`@intCast(-VAR)` — casting a negated runtime integer without guarding against the minimum-value overflow. If `VAR` is a signed integer at its minimum value (`minInt(T)`), the negation `-VAR` overflows before the cast even runs: it panics in Debug/ReleaseSafe and silently wraps to the wrong value in ReleaseFast.

## What the rule checks

The rule fires on the 5-token pattern `@intCast ( - identifier )` — any `@intCast` call whose single argument is a unary negation of an identifier. It does not fire for:
- Integer literals: `@intCast(-1)` — comptime-known, compiler checks overflow
- Non-identifier expressions: `@intCast(-(a + b))` — no match

## Why it matters

The expression `-VAR` for a signed integer is only defined when `VAR != minInt(T)`. For `i64`, `minInt(i64) == -9223372036854775808`; negating that value overflows the `i64` range and wraps to the same negative value in ReleaseFast.

The pattern `@intCast(-VAR)` usually appears in code that wants the unsigned magnitude of a signed value (e.g., converting a negative duration to a positive count). The correct form is `@abs(VAR)`, which is defined for all signed integers including `minInt`.

## Real-world instance

- **ziglang/zig#23318** (`fmtDurationSigned`): `@as(u64, @intCast(-ns))` where `ns: i64`. If `ns == minInt(i64)`, the negation `-ns` overflows `i64` before `@intCast` runs. Fix: replaced with `@abs(ns)`.

## Fix

```zig
// Instead of (overflows when ns == minInt(i64)):
fn formatDuration(ns: i64) u64 {
    if (ns < 0) {
        return @as(u64, @intCast(-ns));
    }
    return @as(u64, ns);
}

// Use @abs which handles minInt correctly:
fn formatDuration(ns: i64) u64 {
    return @abs(ns);
}
```
