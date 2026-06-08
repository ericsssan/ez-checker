# missing-errdefer-on-out-param

A `try <out>.<field>.<acquire>(...)` in a fn that builds a struct
in-place (where `<out>` ∈ {`result`, `out`, `r`} and `<acquire>`
is a resource-acquiring method like `ensureTotalCapacity` /
`init` / `append`), followed by a later `try` in the same fn with
NO `errdefer <out>.<field>.deinit(...)` registered between them.
If the later `try` propagates an error, `<out>.<field>` leaks.

Complements [`missing-errdefer-between-tries`](missing-errdefer-between-tries.md)
which catches the binding-and-leak `const X = try Type.method()`
shape — this rule covers the in-place struct-builder variant
where the acquired resource lives in `<out>.<field>` rather than
a freshly-bound local.

## Why this matters

The struct-builder pattern is idiomatic in Zig: allocate a result
struct on the stack, populate fields one by one with fallible
calls, return the result on success.  Each fallible field-populator
needs its own `errdefer` so that earlier-populated fields are
cleaned up when a later `try` fails.

Without the interleaved errdefers, the partially-populated struct
leaks every resource that was successfully acquired before the
failing call.  The fix is mechanical (one `errdefer` after each
`try`-acquire), but easy to forget — especially when the
resource-acquiring method is `ensureTotalCapacity` rather than
something more obviously allocating.

## Canonical bug (ghostty-org/ghostty#10401)

```zig
pub fn init(alloc: std.mem.Allocator) !SharedGrid {
    var result: SharedGrid = .{ .codepoints = .empty, .glyphs = .empty };
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    try result.glyphs.ensureTotalCapacity(alloc, 128);
    try result.reloadMetrics();   // ← if this fails, both maps leak
    return result;
}
```

## Fix

Interleave `errdefer` after each `try`-acquire:

```zig
pub fn init(alloc: std.mem.Allocator) !SharedGrid {
    var result: SharedGrid = .{ .codepoints = .empty, .glyphs = .empty };
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    errdefer result.codepoints.deinit(alloc);
    try result.glyphs.ensureTotalCapacity(alloc, 128);
    errdefer result.glyphs.deinit(alloc);
    try result.reloadMetrics();
    return result;
}
```

## Why the detector is precise

- Restricted to canonical out-param names (`result`, `out`, `r`)
  — the rule's main precision lever.  Functions building a
  generic struct on a local of any name aren't flagged.
- The acquire chain must be exactly `<out>.<field>.<method>` —
  three-segment.  Deeper chains (`out.foo.bar.append(...)`) and
  shallow ones (`xyz.ensureTotalCapacity(...)`) are out of scope.
- Acquire-method allowlist is narrow: `ensureTotalCapacity`,
  `ensureUnusedCapacity`, `initCapacity`, `init`, `append`,
  `appendSlice`, `put`, `clone`, `dupe`, `alloc`, `create`.
- The errdefer match is loose — any errdefer mentioning the
  token sequence `<out>` `.` `<field>` counts as protection,
  including block-form errdefers and ones with `|err|` captures.
- Acquire sites with no subsequent `try` are skipped (no error
  path to leak on).
