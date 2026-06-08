# intcast-signed-timestamp

**Severity:** error  
**Category:** misc / arithmetic  
**Tier:** 1 (token walk)

## What this checks

`@intCast(std.time.milliTimestamp())` (and the `timestamp`/`nanoTimestamp`
variants) — casting a signed `i64` timestamp directly to an unsigned type
without first guarding against negative values.

`std.time.milliTimestamp()` returns `i64`.  On systems with severe clock skew,
a VM snapshot restore, a deliberate `settimeofday` call, or (rarely) CI runners
with bad clocks, the return value can be negative.  `@intCast(negative_i64)` to
`usize`/`u64`/`u32`:

- **Debug/ReleaseSafe**: panics with integer overflow
- **ReleaseFast**: wraps to a huge positive value (e.g., −1 → `usize.max`),
  producing an absurd PRNG seed, a 292,000-year cache TTL, or an invalid timeout

## Example (fires)

```zig
var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
//                                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                                              fires here — no negative guard
```

## Fix

Wrap in `@max(0, …)` so negative values are clamped to zero:

```zig
var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(@max(0, std.time.milliTimestamp()))));
```

Or guard via a local variable:

```zig
const ms = std.time.milliTimestamp();
var prng = std.rand.DefaultPrng.init(if (ms < 0) 0 else @as(u64, @intCast(ms)));
```

Note: `@intCast(@max(0, std.time.milliTimestamp()))` does **not** fire because
the `@max` wrapper prevents the 8-token pattern from matching.

## Real-world instances

- oven-sh/bun#10365 — `std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())))`;
  on CI runners with clock resets, negative timestamps panicked or seeded the
  PRNG with a garbage value.
