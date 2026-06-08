# aligncast-on-optional-unwrap

`@alignCast(x.?)` — combining a forced optional unwrap with an alignment assertion in the same `@alignCast` call. If `x` is null the forced `.?` panics; if non-null the subsequent alignment check may also panic on unaligned data.

## What the rule checks

The rule fires on the 6-token pattern `@alignCast ( identifier . ? )` — any `@alignCast` call whose single argument is an optional forced-unwrapped with `.?`.

It does not fire when:
- The pointer is non-optional: `@alignCast(ctx)` — no `.?` involved
- The optional is guarded before casting: `@alignCast(ctx orelse return)` — the guard is not inside the `@alignCast` argument

## Why it matters

`@alignCast(x.?)` chains two failure modes:

1. **Null panic**: `.?` panics in Debug/Safe if `x` is null. This silently trusts that the pointer is always non-null — a trust that may be violated by the calling convention, a platform-specific code path, or a race condition.

2. **Alignment panic**: `@alignCast` panics in Debug/Safe if the pointer is not aligned to the required alignment. For context pointers passed through `*anyopaque` (a common C callback pattern), the alignment depends on what was originally stored — which may not match the cast target.

Combining both into a single expression means two runtime invariants are being asserted at once, with no error handling for either failure. The correct approach is to type the pointer as non-optional from the start (eliminating the `.?`) and to ensure alignment statically.

## Real-world instance

- **tigerbeetle/tigerbeetle#3717** (`io: even_listen`): `@ptrCast(@alignCast(ctx.?))` was used to recover a typed pointer from a `?*anyopaque` callback context. If `ctx` was null (possible in some code paths), the forced `.?` would panic. Fix: changed all `?*anyopaque` context parameters to `*anyopaque` throughout the codebase, removing the need for `.?` at every dereference site.

## Fix

```zig
// Instead of (panics on null AND on misalignment):
fn dispatchCallback(ctx: ?*anyopaque) void {
    const self: *Handler = @ptrCast(@alignCast(ctx.?));
    self.handle();
}

// Make the context non-optional at the call site:
fn dispatchCallback(ctx: *anyopaque) void {
    const self: *Handler = @ptrCast(@alignCast(ctx));
    self.handle();
}

// Or guard the optional before casting:
fn dispatchCallback(ctx: ?*anyopaque) void {
    const raw = ctx orelse return;
    const self: *Handler = @ptrCast(@alignCast(raw));
    self.handle();
}
```
