# array-maxint-off-by-one

**Severity:** error  
**Category:** misc / bounds  
**Tier:** 1 (token walk)

## What this checks

`[std.math.maxInt(T)]SomeType` declares an array with `maxInt(T)` slots, so
valid indices are `0 .. maxInt(T) - 1`.  But a value of type `T` ranges from
`0` to `maxInt(T)` inclusive — the maximum value is one past the last valid
index.

In debug builds, indexing with `maxInt(T)` triggers a Zig bounds-check panic.
In `ReleaseFast` / `ReleaseSmall`, it silently reads adjacent memory
(`.rodata`, stack, or heap).

## Example (fires)

```zig
const hex_table: [std.math.maxInt(u8)]u8 = brk: {
    //            ^^^^^^^^^^^^^^^^^^^^^^^  255 slots, indices 0..254
    var table: [std.math.maxInt(u8)]u8 = undefined;
    // ...
    break :brk table;
};

// Later: indexed by any u8 value, including 0xFF = 255 → OOB
const nibble = hex_table[@as(u8, @truncate(raw_byte))];
```

## Fix

Add `+ 1` so that all values of the index type are in range:

```zig
const hex_table: [std.math.maxInt(u8) + 1]u8 = brk: { ... };
// Or equivalently: [256]u8
```

## Real-world instances

- oven-sh/bun#29976 — `hex_table: [255]u8` indexed by decoded hex byte;
  byte `0xFF` panicked in debug / read past `.rodata` in release.
- oven-sh/bun#29973 — `sort_table: [std.math.maxInt(u8)]u8` indexed by
  filename bytes; same OOB on byte `0xFF`.
