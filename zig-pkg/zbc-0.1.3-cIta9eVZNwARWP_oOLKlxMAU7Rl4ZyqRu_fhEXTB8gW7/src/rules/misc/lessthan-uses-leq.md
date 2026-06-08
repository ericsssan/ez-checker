# lessthan-uses-leq

`<=` inside a `lessThan` comparator violates strict weak ordering — `lessThan(a, a)` returns `true` for equal elements, causing `std.sort` to loop indefinitely or produce incorrect results.

## What the rule checks

The rule finds every function named `lessThan` (matching `fn lessThan(`), then scans the function body for any `<=` (`angle_bracket_left_equal`) token using brace-depth tracking to isolate the body from the surrounding code.

It does not fire on `<=` outside a `lessThan` function.

## Why it matters

Zig's sort algorithms (`std.sort.block`, `std.sort.pdq`, etc.) require the comparator to implement **strict weak ordering**:

- **Irreflexivity**: `lessThan(a, a)` must return `false`.
- **Asymmetry**: if `lessThan(a, b)` then `!lessThan(b, a)`.
- **Transitivity**: if `lessThan(a, b)` and `lessThan(b, c)` then `lessThan(a, c)`.

Using `<=` in the final tiebreaker violates irreflexivity: when `a` and `b` are equal, both `lessThan(a, b)` and `lessThan(b, a)` return `true` simultaneously. Many sort algorithms rely on `!lessThan(a, b) && !lessThan(b, a)` to detect equivalence; when that invariant is broken:

- Loop termination conditions become unreachable → **infinite loop**.
- Element ordering is non-deterministic → **incorrect sort output**.
- Internal invariants of the sort algorithm are violated → **heap corruption** (for heap-sort variants).

## Real-world instance

- **oven-sh/bun#24146** (sourcemap sort): `Mapping.List.LessThan.lessThan` returned `a.lines < b.lines or (a.lines == b.lines and a.columns <= b.columns)`. When `a.lines == b.lines and a.columns == b.columns`, both `lessThan(a, b)` and `lessThan(b, a)` returned `true`, breaking `std.sort.block`'s loop termination invariant. Fix: replaced `<=` with `<` and added an index tiebreaker.

## Fix

```zig
// Instead of (violates strict weak ordering for equal elements):
fn lessThan(ctx: void, a: Mapping, b: Mapping) bool {
    _ = ctx;
    return a.line < b.line or (a.line == b.line and a.col <= b.col);
}

// Use strict less-than with a deterministic tiebreaker:
fn lessThan(ctx: void, a: Mapping, b: Mapping) bool {
    _ = ctx;
    if (a.line != b.line) return a.line < b.line;
    if (a.col != b.col) return a.col < b.col;
    return a.index < b.index; // stable tiebreaker on original position
}
```
