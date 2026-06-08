# impossible-range-and

**Severity:** error  
**Category:** misc / logic  
**Tier:** 1 (token walk)

## What this checks

`x < A and x > B` — an out-of-range guard that uses `and` instead of `or`.

No value can simultaneously be less than a lower bound `A` and greater than
an upper bound `B` (when `A ≤ B`).  The `if` body is permanently dead code:
the `throwRangeError`, `return error`, or other handler it contains never
fires.

Note: `x > A and x < B` (the valid *in-range* check) is **not** flagged.

## Example (fires)

```zig
if (retry < 0 and retry > 255) {
    //         ^^^  should be `or`
    return error.OutOfRange;  // ← unreachable; `retry` can never be both
}
```

## Fix

Replace `and` with `or`:

```zig
if (retry < 0 or retry > 255) {
    return error.OutOfRange;  // now fires when retry is negative OR > 255
}
```

## Real-world instances

- oven-sh/bun#25905 (`src/s3/credentials.zig`) — three adjacent copy-paste
  dead guards: `pageSize < MIN and pageSize > MAX`, `partSize < MIN and
  partSize > MAX`, `retry < 0 and retry > 255`.  None of the `throwRangeError`
  calls ever fired regardless of the input value.
