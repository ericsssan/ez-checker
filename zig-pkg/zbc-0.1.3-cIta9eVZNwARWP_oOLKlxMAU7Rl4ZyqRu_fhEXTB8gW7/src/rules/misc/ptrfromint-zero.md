# ptrfromint-zero

**Severity:** error  
**Category:** null pointer / UB  
**Tier:** 1 (token walk)

## What this checks

`@ptrFromInt(0)` — creating a pointer from the null address.

In Zig, non-nullable pointer types (`*T`, `[*]T`, `*const T`, etc.) must
never hold the value 0.  `@ptrFromInt(0)` manufactures such a pointer.
On every major platform address 0 is an invalid user-space address:
- **Debug / ReleaseSafe**: dereferencing traps with a segfault or assertion.
- **ReleaseFast**: dereferencing is silent undefined behaviour — may read
  garbage, corrupt memory, or enable an attacker-controlled write.

## Example (fires)

```zig
// BUG: creates a dangling pointer; any dereference is UB
const sentinel: *Header = @ptrFromInt(0);
```

## Fix

Use an optional pointer instead:

```zig
const sentinel: ?*Header = null;
```

Or, for pointer arithmetic starting at 0 and building up to a real address,
stay in integer space:

```zig
const base: usize = 0;
const offset: usize = @offsetOf(Header, "magic");
const addr = base + offset;  // keep as usize until you have a real base
```

## Note

`@ptrFromInt` with non-zero values is legitimate (MMIO registers, custom
allocators, FFI shims).  Only the literal `0` argument is flagged.
