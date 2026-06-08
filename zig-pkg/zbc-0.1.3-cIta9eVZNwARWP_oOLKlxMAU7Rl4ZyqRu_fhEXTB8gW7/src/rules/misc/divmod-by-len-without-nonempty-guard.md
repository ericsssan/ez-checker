# divmod-by-len-without-nonempty-guard

**Severity:** error
**Category:** misc / division by zero
**Tier:** semantic (value-range oracle + type engine)

## What this checks

Integer division or modulo by a container length — `x / c.len` or `x % c.len` —
where `c` is not proven non-empty. When `c.len == 0`, the `/` or `%` is a
division by zero: in Zig this is safety-checked illegal behaviour — it panics
in Debug/ReleaseSafe and is undefined behaviour in ReleaseFast.

```zig
const avg = total / items.len;     // panics when items is empty
const slot = hash % buckets.len;   // panics when buckets is empty
```

## Why a semantics-first rule

Firing on every `/ c.len` would be unusable: most such divisions are over
provably non-empty containers (fixed-size arrays, slices guarded by a prior
emptiness check). This rule only fires when it **cannot prove** the container
is non-empty, using two sound queries:

- **value-range oracle** — a dominating guard establishes non-emptiness:
  `if (c.len > 0)`, `if (c.len != 0)`, `if (c.len == 0) return`, or a
  length-snapshot `const n = c.len; if (n > 0)`.
- **type engine** — `c` is a fixed array `[N]T` with `N >= 1`, so `c.len` is a
  non-zero compile-time constant.

## Examples

Fires:

```zig
fn average(items: []const u32, total: u32) u32 {
    return total / items.len;   // items may be empty
}
```

Does not fire (guarded):

```zig
fn average(items: []const u32, total: u32) u32 {
    if (items.len == 0) return 0;
    return total / items.len;
}
```

Does not fire (fixed-size array — length is a non-zero constant):

```zig
const channels = [_]Channel{ .red, .green, .blue };
fn pick(i: usize) Channel {
    return channels[i % channels.len];
}
```

## Fix

Guard the divisor, or prove the container is non-empty before dividing:

```zig
if (items.len == 0) return error.Empty;
const avg = total / items.len;
```

## Scope

v1 matches only a bare `<path>.len` divisor immediately after a binary `/`
(integer division). Modulo (`%`) by `.len` is intentionally excluded: in
practice it is dominated by ring-buffer / index-wrap idioms over containers that
are non-empty by construction (capacity asserted in a constructor the analyzer
cannot see), which would be false positives. Extending to `%` cleanly needs
cross-method capacity-invariant tracking.

A parenthesized or arithmetic divisor (`/ (c.len + 1)`) cannot be zero and is
not matched; float division never traps and is excluded by construction
(`.len` is `usize`).
