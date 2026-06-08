# arraylist-sentinel-write-without-capacity

**Severity:** error  
**Category:** out-of-bounds / collection  
**Tier:** 1 (token walk)

## What this checks

A direct write to `list.items[list.items.len]` — one past the end of the
initialized region — without first ensuring the ArrayList has spare capacity.

When `items.len == capacity` (the list is exactly full), this write goes
beyond the backing allocation and hits allocator bookkeeping bytes.  In
Debug/ReleaseSafe mode this triggers a safety-checked OOB trap; in
ReleaseFast it silently corrupts the heap.

## Example (fires)

```zig
// BUG: items.len == capacity → write past end of allocation
output.items[output.items.len] = 0;
return output.items[0..output.items.len + 1 :0];
```

## Fix

Ensure capacity before writing the sentinel:

```zig
try output.ensureUnusedCapacity(1);
output.appendAssumeCapacity(0);
return output.items[0..output.items.len - 1 :0];
```

Or use `toOwnedSliceSentinel`:

```zig
return try output.toOwnedSliceSentinel(0);
```

## Real-world instance

- oven-sh/bun#29982 — `toUTF16Alloc` sentinel branch wrote
  `output.items[output.items.len] = 0` without `ensureUnusedCapacity(1)`.
  The fix added the capacity check and changed to `appendAssumeCapacity`.
