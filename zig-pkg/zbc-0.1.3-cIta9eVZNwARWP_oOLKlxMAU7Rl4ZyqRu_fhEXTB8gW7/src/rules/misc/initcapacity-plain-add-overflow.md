# initcapacity-plain-add-overflow

**Severity:** error  
**Category:** misc / integer overflow / allocation  
**Tier:** 1 (token walk)

## What this checks

`initCapacity(allocator, size + N)` where `N` is a small integer literal and
`size` is an identifier that could be near `maxInt(usize)`.  The plain `+`
addition is evaluated in `usize` without overflow checking; when `size` is
close to `maxInt(usize)`, `size + N` wraps to a small value, causing
`initCapacity` to allocate far less memory than required.

Subsequent writes beyond the actual capacity corrupt the heap or panic.

The fix is to use saturating addition `+|` so the result caps at
`maxInt(usize)` rather than wrapping:

```zig
try ArrayList(u8).initCapacity(allocator, size +| 16);
```

Or, if a smaller capacity is acceptable, use `@min`:

```zig
try ArrayList(u8).initCapacity(allocator, @min(size, max_cap) + 16);
```

## Example (fires)

```zig
var buf = try std.ArrayList(u8).initCapacity(allocator, this.size + 16);
//                                                       ^^^^^^^^^^^ wraps when size near maxInt
```

## Fix

```zig
var buf = try std.ArrayList(u8).initCapacity(allocator, this.size +| 16);
```

## Real-world instances

- oven-sh/bun#29284 — `src/bun.js/webcore/blob/read_file.zig`:
  `initCapacity(bun.default_allocator, this.size + 16)` — fixed to
  `this.size +| 16` (saturating add) to prevent overflow when reading
  a large file whose size is near `maxInt(usize)`.
- oven-sh/bun#26999 — cron parser `std.array_list.Managed(u8).initCapacity(allocator, input.len + 16)` —
  same pattern; `input.len` near `maxInt(usize)` would wrap `+16` to 15
  (or smaller), silently under-allocating the output buffer.
