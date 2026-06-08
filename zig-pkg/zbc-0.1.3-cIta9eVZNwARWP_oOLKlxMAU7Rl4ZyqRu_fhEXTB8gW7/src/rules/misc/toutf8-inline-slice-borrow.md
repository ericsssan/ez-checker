# toutf8-inline-slice-borrow

`.toUTF8(alloc).slice()` written as an inline chain — the `LazyUTF8` temporary created by `toUTF8()` is freed at statement end, so the returned `[]const u8` immediately points into freed memory.

## What the rule checks

The rule fires on two forms of the inline chain pattern:

- **Form A**: `something.toUTF8(allocator).slice()` — single identifier allocator
- **Form B**: `something.toUTF8(obj.field).slice()` — field-access allocator (e.g. `bun.default_allocator`)

The safe pattern — storing the `LazyUTF8` in a local variable with `defer deinit()` — has `.slice()` on a separate token from the `toUTF8()` call, so it does not fire.

## Why it matters

In Zig, `toUTF8(alloc)` returns a `LazyUTF8` value that owns its backing buffer. When chained inline as `.toUTF8(alloc).slice()`, Zig evaluates the chain as:

1. Create a temporary `LazyUTF8` value (allocates or borrows the backing buffer)
2. Call `.slice()` on the temporary (returns `[]const u8` pointing into the buffer)
3. Destroy the temporary — **the backing buffer is freed**
4. The returned `[]const u8` now points into freed memory

Any downstream use of that slice — storing it in a heap struct, passing it to a function that holds it past the statement — is a use-after-free.

## Real-world instance

**oven-sh/bun#29600** (ResolveMessage): `referrer.toUTF8(bun.default_allocator).slice()` was passed to `ResolveMessage.create()`, which stored the slice in a heap-allocated JS error object. The temporary buffer was freed immediately after the statement, leaving the error object's `.referrer` field as a dangling pointer that corrupted memory when the JS error's `referrer` property was later read.

## Fix

Bind the `LazyUTF8` to a local and add `defer deinit()`:

```zig
// Instead of:
const name = something.toUTF8(alloc).slice();

// Use:
const utf8 = something.toUTF8(alloc);
defer utf8.deinit(alloc);
const name = utf8.slice();
```
