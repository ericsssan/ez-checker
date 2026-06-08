# hashmap-getentry-forced-unwrap

`.getEntry(key).?` — forced optional unwrap on the result of `HashMap.getEntry`. `getEntry(key)` returns `?Entry`; when the key is absent the result is null and the forced `.?` panics.

## What the rule checks

The rule fires on `getEntry(…).?` — any call to `getEntry` whose result is immediately force-unwrapped with `.?`. It uses a paren-balanced scan to find the closing `)` of the argument list, then checks whether `.?` (a `.period` followed by `.question_mark`) immediately follows.

It does not fire when:
- The result is bound and checked: `if (map.getEntry(k)) |entry| { … }`
- The result is guarded with `orelse`: `map.getEntry(k) orelse return`
- The result is stored in a variable without an immediate `.?`

## Why it matters

`std.HashMap.getEntry(key)` returns `?Entry` because the key may not be present. Forcing the optional with `.?` trusts that the key is always present — but this assumption can be violated by:

- **Concurrent mutations**: A callback executed before `.getEntry` may have removed the key
- **Code path changes**: A refactor that changes the set of keys stored in the map
- **Off-by-one in the caller**: The caller passing a key that was never inserted

When the assumption is violated, the forced `.?` panics in Debug/Safe builds and invokes undefined behaviour in ReleaseFast. Because the panic fires at the `.?` site rather than at the site that removed the key, it can be difficult to diagnose.

## Real-world instance

- **oven-sh/bun#14606** (H2 stream handling): `this.streams.getEntry(stream_id).?.value_ptr` was called after a callback dispatch that may have removed `stream_id` from the map; the forced `.?` panicked at runtime. Fix: added `orelse return` guard before the unwrap.

## Fix

```zig
// Instead of (panics when key absent):
const entry = map.getEntry(key).?;

// Guard with orelse:
const entry = map.getEntry(key) orelse return;

// Or check explicitly:
if (map.getEntry(key)) |entry| {
    _ = entry.value_ptr.*;
}
```
