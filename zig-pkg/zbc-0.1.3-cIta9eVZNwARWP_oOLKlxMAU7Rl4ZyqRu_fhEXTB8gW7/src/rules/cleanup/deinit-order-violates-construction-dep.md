# deinit-order-violates-construction-dep

Within a single fn body, `<A> = <T>.init(&<B>, ...)` creates a
dep edge B→A (A borrows from B).  Later `<B>.deinit(...)` runs
BEFORE `<A>.deinit(...)`.  A's deinit may dereference its
borrowed pointer to B — but B is already torn down → UAF.

Canonical LIFO invariant: deinit in REVERSE construction order.

## Canonical bug (tigerbeetle/tigerbeetle#3732)

```zig
env.grid_verify = try Grid.init(...);
env.manifest_log_verify = try ManifestLog.init(&env.grid_verify, ...);
// ...
env.grid_verify.deinit();           // ← BUG: parent first
env.manifest_log_verify.deinit();   // ← child uses dangling parent
```

## Fix

```zig
env.manifest_log_verify.deinit();   // child first
env.grid_verify.deinit();           // parent last
```

## Why the detector is precise

- Dep edges are collected only from explicit `.init(&<B>, ...)`
  shapes — passing by VALUE doesn't create a borrow dep.
- Receiver names are flattened to their LAST identifier
  segment, so chains like `env.grid_verify` and
  `env.manifest_log_verify` compare by `grid_verify` /
  `manifest_log_verify`.
- Fires on the LATER deinit (the child whose dep is gone).

## Limitations

- Only catches deinit pairs within a single fn body.
- Doesn't distinguish "init takes &B for read-only" from "init
  stores &B" — the latter is the actual UAF case, but both
  shapes look the same syntactically.
