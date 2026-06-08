# tryget-orelse-unreachable

`tryGet() orelse unreachable` — `tryGet()` returns `null` for finalized JSRef objects, so `orelse unreachable` becomes SIGILL (ReleaseFast) or a panic (safe builds) when called after the object has been finalized.

## What the rule checks

The rule fires on the 5-token pattern `tryGet() orelse unreachable` inside function bodies. It does not fire on `tryGet() orelse return` or `tryGet() orelse null` — those handle the null case explicitly and are correct.

## Why it matters

`tryGet()` on a `JSRef` (bun's reference type for JavaScript heap objects) is designed to return `null` when the backing `JSObject` has been finalized. It exists precisely to handle the case where the JS GC has destroyed the object while a native struct still holds a reference.

Using `orelse unreachable` asserts at the call site that finalization can never happen before this code runs — an assertion that breaks in any callback-heavy, event-driven code where finalization timing is non-deterministic.

## Real-world instance

**oven-sh/bun#29210** (valkey client): `updatePollRef()` called `subscriptionCallbackMap()` which did `this.parent().this_value.tryGet() orelse unreachable`. The `updatePollRef` method could be called by `uv_poll` callbacks after the client's `finalize()` had already set `flags.finalized`. Once finalized, `tryGet()` returns `null`, the `unreachable` branch fires as SIGILL in release builds.

Fix: add `if (this.client.flags.finalized) return;` at the top of `updatePollRef`.

## Fix

```zig
// Instead of:
const parent = this.jsValue.tryGet() orelse unreachable;

// Guard against finalization:
if (this.flags.finalized) return;
const parent = this.jsValue.tryGet() orelse return;

// Or propagate null to the caller:
const parent = this.jsValue.tryGet() orelse return null;
```
