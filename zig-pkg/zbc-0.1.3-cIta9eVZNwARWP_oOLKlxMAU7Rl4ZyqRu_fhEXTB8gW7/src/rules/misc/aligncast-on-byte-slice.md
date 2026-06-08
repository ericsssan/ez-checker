# aligncast-on-byte-slice

`@alignCast(expr.ptr)` — asserting alignment on a raw byte-slice pointer is unsafe. For network buffers, memory-mapped files, and serialised binary data the pointer offset is arbitrary; the runtime alignment check in `@alignCast` panics in safe builds when the offset is not a multiple of the target alignment.

## What the rule checks

The rule fires on two forms:

- **Form A**: `@alignCast(identifier.ptr)` — direct alignment assertion on a `.ptr` field
- **Form B**: `@alignCast(@constCast(identifier.ptr))` — constCast then alignCast on a `.ptr` field

`@ptrCast(@alignCast(expr.ptr))` also contains Form A or B as a sub-expression and fires.

## Why it matters

In Zig, `.ptr` on a `[]const u8` slice returns a raw `[*]const u8` pointer whose alignment depends on where the data came from — the allocator, memory-mapping offset, or network socket buffer position. There is no guarantee it is aligned to anything other than `align(1)`.

`@alignCast(ptr)` inserts a runtime assertion that the pointer satisfies the target type's alignment requirement. For a `*Header` with 4-byte fields, that means the pointer address must be divisible by 4. Network packets can arrive at any offset; `@memcpy` into a newly-allocated buffer starts at any offset within an arena page.

The panic is non-deterministic: it depends on the alignment of the allocator's current free pointer, which varies by run and by the size of preceding allocations.

## Real-world instances

- **oven-sh/bun#27082** (Postgres binary arrays): `@ptrCast(@alignCast(@constCast(bytes.ptr)))` on network-received packet data; panicked non-deterministically on odd-offset packets.
- **oven-sh/bun#27281** (sourcemap deserialisation): `@ptrCast(@alignCast(raw.ptr))` on a memory-mapped file; panicked on unaligned mmap regions.
- **oven-sh/bun#27384** (tagged-pointer sockets): `@alignCast(data.ptr)` into a tagged-pointer arena.
- **oven-sh/bun#27290** (HTTP response parsing): `@alignCast(@constCast(bytes.ptr))` on response buffers.

## Fix

```zig
// Instead of overlaying a struct on a byte slice:
const header: *Header = @ptrCast(@alignCast(bytes.ptr));

// Use readInt for integer fields:
const magic = std.mem.readInt(u32, bytes[0..4], .big);

// Or copy into a local aligned struct:
var header: Header = undefined;
@memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);
```
