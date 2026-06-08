# uv-return-value-intcast-truncation

`@intCast(rc.int())` — `ReturnCode.int()` returns `c_int` (32-bit signed), but the underlying libuv `req.result` is `ssize_t` (64-bit on 64-bit platforms). For I/O operations larger than 2 GB the 32-bit value wraps to a negative number, and `@intCast` to `usize` panics in safe builds.

## What the rule checks

The rule fires on two forms:

- **Form A**: `@intCast(rc.int())` — single identifier before `.int()`
- **Form B**: `@intCast(req.rc.int())` — field-access chain before `.int()`

Using `@as(T, rc.int())` does not fire — the pattern specifically targets `@intCast` which performs a runtime bounds check that fails when the 32-bit value is negative.

## Why it matters

libuv's `uv_fs_read` and `uv_fs_write` return `int` (32-bit) for the synchronous result, but the underlying `uv_fs_t.result` field is `ssize_t` (64-bit). Bun's `uv.ReturnCode.int()` wrapper returns `c_int` (32-bit), losing the upper 32 bits for large transfers. When a single read/write call handles more than `INT_MAX` (~2.1 GB) bytes:

1. The `c_int` return wraps to a negative value
2. `@intCast(negative_value)` targeting `usize` panics in Debug/Safe builds
3. In ReleaseFast the cast produces a huge `usize` value, corrupting the byte count

## Real-world instance

**oven-sh/bun#29327** (Windows `readFile`): `@intCast(rc.int())` panicked on files larger than 2 GB because `.int()` returned the truncated 32-bit libuv result. Fix: read `req.result` (the untruncated `ssize_t`) directly instead of going through `rc.int()`.

## Fix

```zig
// Instead of:
const bytes_read: usize = @intCast(rc.int());

// Read the untruncated result directly:
const bytes_read: usize = @intCast(req.result);
```
