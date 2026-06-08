# truncate-subtraction-without-guard

**Severity:** error  
**Category:** misc / integer overflow / bounds  
**Tier:** 1 (token walk)

## What this checks

`@truncate(a - b)` (or the field-access form `@truncate(recv.field - other)`)
where the subtraction is performed without a prior guard that `a >= b`.
When `b > a`, the unsigned subtraction wraps to a huge value before
`@truncate` narrows it, producing a garbage result.

In Zig all unsigned subtraction can underflow.  The `@truncate` call does
NOT prevent the underflow — it merely discards the high bits of an
already-wrong value.

## Example (fires)

```zig
// BUG: if read_size > this.packet_size the subtraction wraps before @truncate
const remaining: u32 = @truncate(this.packet_size - read_size);
```

## Fix

Add an explicit guard before the subtraction:

```zig
if (this.packet_size > read_size) {
    const remaining = this.packet_size - read_size;
    this.info = try reader.read(@truncate(remaining));
}
```

Or use saturating subtraction and check for zero:

```zig
const remaining = this.packet_size -| read_size;
if (remaining > 0) {
    this.info = try reader.read(@truncate(remaining));
}
```

## Real-world instances

- oven-sh/bun#23993 — `src/sql/mysql/protocol/OKPacket.zig`:
  `@truncate(this.packet_size - read_size)` without a `packet_size > read_size`
  guard; when `read_size` exceeded `packet_size` the subtraction wrapped and
  `@truncate` produced a garbage length, causing an OOB read.
- oven-sh/bun#6761 / oven-sh/bun#29905 — `src/bun.js/api/bun/h2_frame_parser.zig`:
  `const end = payload.len - padding` (PR #6761 introduced the bug);
  PR #29905 added `if (@as(usize, padding) >= frame.length)` and
  `if (padding > payload.len - offset)` guards to prevent the underflow.
