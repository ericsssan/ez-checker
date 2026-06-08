# writeint-truncated-value

`writeInt(NarrowType, @as(NarrowType, @truncate(EXPR)), endian)` — writing a value via `writeInt` where the value argument is an explicit `@as(T, @truncate(...))` coercion. The `@truncate` silently discards high bits of the source value in all build modes; for values that may exceed the narrow type's range (e.g., 64-bit addresses, large symbol offsets) this corrupts the serialized output without any error or panic.

## What the rule checks

The rule fires on the 9-token pattern `writeInt ( identifier , @as ( identifier , @truncate` — any `writeInt` call whose value argument begins with `@as(T, @truncate(...))`. It does not fire when:
- The value is passed directly without `@truncate`
- An explicit bounds check or range assertion precedes the call

## Why it matters

`@truncate` discards high-order bits to fit a wider integer into a narrower type. When used inside a `writeInt` call, the truncation happens before the write — the serialized output will contain incorrect data for any value exceeding the target type's range. Unlike `@intCast`, which panics in Debug/ReleaseSafe on overflow, `@truncate` is silent in every build mode.

The pattern `writeInt(i32, @as(i32, @truncate(wide_expr)), endian)` is usually a leftover from code that was later widened: the source expression changed to `i64` but the `writeInt` call (and its truncation) was not updated.

## Real-world instance

- **ziglang/zig#22233** (`Elf.Atom` dynamic absolute relocs): `writer.writeInt(i32, @as(i32, @truncate(S + A)), .little)` where `S + A` is `i64`. For symbol + addend values above 2 GB, the truncation silently dropped the upper 32 bits, corrupting ELF dynamic relocation entries. Fix: widened to `writer.writeInt(i64, S + A, .little)`.

## Fix

```zig
// Instead of (silently truncates high bits):
try writer.writeInt(i32, @as(i32, @truncate(S + A)), .little);

// Widen the target type to match the actual value width:
try writer.writeInt(i64, S + A, .little);

// Or, if truncation is intentional and bounded, add an explicit check:
std.debug.assert(S + A >= std.math.minInt(i32) and S + A <= std.math.maxInt(i32));
try writer.writeInt(i32, @intCast(S + A), .little);
```
