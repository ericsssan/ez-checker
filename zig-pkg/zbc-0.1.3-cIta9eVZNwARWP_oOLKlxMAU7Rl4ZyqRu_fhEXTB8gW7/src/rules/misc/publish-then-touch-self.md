# publish-then-touch-self

`<chain>.<publish-method>(this);` (or `(self)`) where the chain or
method suggests concurrent / cross-thread dispatch — followed by
any further use of `this`/`self` in the same scope.  The consumer
thread may have freed `this` before the second access lands.

Concurrent dispatch is identified by:
- Method name containing `Concurrent`, `Thread`, `Cross`, `Async`,
  or being one of `postToMain` / `postTask` / `scheduleTask` /
  `spawn` / `dispatch`.
- Receiver chain containing `queue`, `pool`, `thread`,
  `cross_thread`, `concurrent`, `dispatcher`, `scheduler`,
  `work_pool` / `workPool` / `thread_pool` / `threadPool`, OR
  any compound identifier containing `"queue"` (e.g. `task_queue`,
  `patch_task_queue`, `async_network_task_queue`) or ending in
  `_pool` / `Pool`.

A **deferred use** that appears before the publish in source text is
also flagged — `defer this.X` fires at function exit, which is AFTER
the publish, making it an equivalent hazard:

```zig
// BUGGY — the deferred wake fires AFTER push:
pub fn notify(this: *Task) void {
    defer this.manager.wake();                     // ← fires at fn exit
    this.manager.patch_task_queue.push(this);      // ← publish
}
// Fix: hoist manager before publish, use local in defer
pub fn notify(this: *Task) void {
    const mgr = this.manager;
    this.manager.patch_task_queue.push(this);
    mgr.wake();
}
```

## Why this matters

Once `this`/`self` has been handed to a different thread (via a
lock-free queue, a thread pool task slot, a cross-thread channel),
the consumer is free to run, complete, and FREE the object before
the publishing thread executes its next instruction.  Any further
read or method call on `this` from the publisher is a
cross-thread use-after-free.

The canonical Bun pattern (from oven-sh/bun#29128):

```zig
// BUGGY:
transpiler_store.queue.push(this);                                     // ← publish
vm.eventLoop().enqueueTaskConcurrent(jsc.ConcurrentTask.createFrom(transpiler_store));
// `this` (and via the previous publish, `transpiler_store`)
// may already have been freed by the worker thread.
```

The fix hoists all post-publish reads into LOCALS before the publish:

```zig
const vm = this.vm;
const transpiler_store = &vm.transpiler_store;
transpiler_store.queue.push(this);
// `this` is now untouchable — must not be accessed again.
vm.eventLoop().enqueueTaskConcurrent(jsc.ConcurrentTask.createFrom(transpiler_store));
```

## Why the detector is precise

- Two layered signals — method-name AND receiver-chain — keep the
  match tight.  `list.append(this)` (not concurrent) doesn't fire;
  `queue.push(this)` (concurrent) does.
- Argument must be EXACTLY `this` or `self` (bare identifier).
  `queue.push(self.field)` is a different shape (already covered
  by other rules or is benign — `self.field` is a sub-object whose
  lifetime may be tied to a different owner).
- Use-after detection is scope-bounded — past the enclosing `}`
  the rule doesn't continue.  No false positives from same-name
  identifiers in sibling scopes.
- Deferred-use check scans backward from the publish for `defer
  this.X` / `defer { this.X; }` patterns that fire after function
  exit — i.e., after the publish.
- **Type-inference suppression** eliminates false positives on
  slice-element and pool-managed objects.  Two-tier check:
  - *Tier-1*: resolve the receiver param's declared type in the
    current file (via `FileCache.paramContainerName`); if that type
    has no method with `takes_ownership_of == 0` (no direct
    `.destroy(this)` / `.free(this)`) the object isn't individually
    heap-managed → suppress.
  - *Tier-2 fallback* (for file-level structs and `@fieldParentPtr`
    locals where the type can't be resolved): if NO function in the
    entire file directly calls `.destroy(param0)` / `.free(param0)`,
    nothing in the file is heap-managed → suppress.

Limitations (deliberate):
- Doesn't track aliased publishes (`const x = this; queue.push(x);
  this.field;` — `this` aliased through `x`).
- Doesn't distinguish "publish that may not actually run on another
  thread" (e.g., synchronous deferred callbacks).
- Compound queue/pool name matching uses substring search, so
  a pathological `notARealQueue.push(this)` might match; the
  requirement for an explicit publish method (`push`/`send`/etc.)
  still applies and keeps FPs low in practice.
- Type inference is file-local only: if a type's destructor lives
  in a different file (e.g. `bun.destroy` wrapping a cross-file
  `deinit`), tier-2 conservatively keeps the finding.
