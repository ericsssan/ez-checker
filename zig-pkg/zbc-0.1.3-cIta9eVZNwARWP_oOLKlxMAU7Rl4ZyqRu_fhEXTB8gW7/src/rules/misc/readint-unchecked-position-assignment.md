# readint-unchecked-position-assignment

**Severity:** error  
**Category:** out-of-bounds / deserialization  
**Tier:** 3 (LocalBindings)

## What this checks

A value deserialized from untrusted data via a `readInt`-family method
(`readInt`, `readIntLittle`, `readU64`, `readU32`, `readByte`, etc.) is
assigned directly to a position/cursor/offset field (`pos`, `position`,
`offset`, `cursor`, `index`, `idx`, `start`, `end`) without a preceding
bounds check.

The deserialized integer is attacker-controlled.  Assigning it to a cursor
field without validation means any downstream slice like
`stream.buffer[stream.pos..]` will trap in Debug/Safe mode or silently
read out-of-bounds memory in ReleaseFast.

## Example (fires)

```zig
pub fn readArray(stream: *Stream, reader: anytype) !void {
    const end_pos = try reader.readInt(u64, .little);
    stream.pos = end_pos;  // ← BUG: end_pos may exceed stream.buffer.len
    _ = stream.buffer[start..end_pos];  // OOB
}
```

## Fix

Validate the deserialized value before assigning it to the cursor:

```zig
pub fn readArray(stream: *Stream, reader: anytype) !void {
    const end_pos = try reader.readInt(u64, .little);
    if (end_pos > stream.buffer.len) return error.CorruptData;
    stream.pos = end_pos;
}
```

## Real-world instance

- oven-sh/bun#12105 — `lockfile.zig` `Buffers.readArray`: both `start_pos`
  and `end_pos` were read from untrusted lockfile data and used to set
  `stream.pos` and slice `stream.buffer` without any validation that they
  are within bounds.
