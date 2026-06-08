# truncate-len-to-narrow-int

`@truncate(X.len)` — silently discards the upper bits of a slice length. For user-controlled data (files, network payloads, form fields) a length larger than the target integer's maximum wraps to a small value, corrupting all subsequent size-based reads, copies, and allocations.

## What the rule checks

The rule fires on two forms:

- **Form A**: `@truncate(identifier.len)` — direct truncation of a `.len` field
- **Form B**: `@truncate(identifier.field.len)` — truncation of a nested `.len` field

`@as(u32, @truncate(X.len))` contains Form A as a sub-expression and also fires.

## Why it matters

In Zig, `.len` on a slice is `usize` — 64 bits on 64-bit platforms. `@truncate` discards high bits without any runtime check. When the source slice is user-controlled (file content, HTTP body, form field, network message), an attacker or user with a large enough input can make the truncated length wrap to an arbitrary small value.

The resulting truncated size is used as the authoritative length for subsequent operations: allocations, copies, reads, and bounds checks all operate on the wrapped value. Data is silently lost and the program continues with a corrupted view of the data.

## Real-world instance

**oven-sh/bun#27443** (multipart form-data): `bun.Semver.String` stored `length: u32`. The conversion used `@as(u32, @truncate(in.len))` to set the length when processing multipart body parts. For bodies ≥ 4 GB (or when an attacker provided a boundary-crafted payload that caused an intermediate slice to appear that large), the truncated length was wrong, and the subsequent read used the corrupted size — silently dropping bytes.

Fix: replaced the `u32`-bounded `Semver.String` with a plain `[]const u8` (pointer + `usize` length), eliminating the truncation entirely.

## Fix

```zig
// Instead of:
s.length = @truncate(buf.len);  // silent data loss for buf.len >= 4 GB

// Use the full usize:
s.length = buf.len;  // widen the storage type

// Or validate the length explicitly:
if (buf.len > std.math.maxInt(u32)) return error.InputTooLarge;
s.length = @intCast(buf.len);  // @intCast checks in safe mode
```
