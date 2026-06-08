# thread-spawn-local-pointer

`Thread.spawn(.{}, fn, .{ &<local>, ... })` /
`<pool>.spawn(fn, .{ &<local>, ... })` — passing the address of
a function-LOCAL into a spawned thread.  The thread keeps
running after the spawning fn returns; the local dies with the
frame; the thread now reads/writes through a dangling pointer.

## Shape

```zig
pub fn run_async(...) !void {
    var ctx = Context{ .counter = 0 };
    const t = try std.Thread.spawn(.{}, worker, .{&ctx});  // ← &ctx dangling after this fn returns
    t.detach();  // ← thread keeps running with the dangling ptr
}
```

The thread runs independently after `detach()`.  When `run_async`
returns, `ctx`'s stack slot is reclaimed; the thread now races on
freed memory.

## Detection

Per-fn token walk:
1. Find call sites `<recv>.spawn(...)` / `<recv>.spawnTask(...)`.
2. Discriminator: the last call argument must start with `.{` —
   Zig's `Thread.spawn(.{}, fn, .{args})` / pool's
   `.spawn(fn, .{args})` shape.  Calls with a different shape
   (libuv-style `uv.spawn(loop, &opts)`) are skipped — the
   trailing `&opts` is an out-param consumed synchronously, not
   a captured args struct.
3. Scan the args struct literal for `& <ident>` where `<ident>`
   is a function-local (not a param, not a heap-allocated value,
   not a static).
4. Sync skip: if the rest of the fn body contains `.join()` /
   `.joinAll()` / `.wait()` / `.await()` / `.waitForCompletion()` /
   `.waitAndWork()` / `.deinit()` (the spawning fn explicitly
   synchronises with the worker before returning), suppress —
   the worker can't outlive the local.
5. Fire on the `&<local>` site otherwise.

## Sibling rules

- `stack-escape` — `return &<local>` and `recv.field = &<local>`
  through param-shape receivers.  This rule extends the same
  hazard class to threaded code where the worker's lifetime is
  independent of the call stack.
- `arena-escape` — similar lifetime mismatch but for arenas
  passed across spawn boundaries.

## Coverage limits

- Conservative on method names: only `spawn` / `spawnTask`.
  `schedule` is ambiguous (`thread_pool.schedule(batch)` vs
  `batch.schedule(...)` builder) and would cause FPs.
- The sync-call skip is a "presence anywhere" check; it doesn't
  prove the join is reached on all paths (e.g. early `return`
  before the join).  This biases toward false negatives, not
  false positives.
- `&<container>.<field>` (multi-segment receivers) is left to
  `stack-escape` — captures via composite-borrow rather than
  raw `&<local>`.

## Real-world

The "spawn + detach + dangling local" shape is a recurring Zig
threading footgun.  Stack-allocated args are safe ONLY when the
spawning fn explicitly joins before returning.
