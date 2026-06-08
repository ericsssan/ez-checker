# exit-callback-cross-thread

A function is registered as an at-exit or cross-thread callback (via
`add_exit_callback`, `addExitCallback`, `onExit`, `atexit`, etc.) but its
body accesses mutable state (via `self.` field accesses) without a
`is_main_thread()` / `isMainThread()` / `isCLIThread()` guard.  When
process exit is triggered from a worker thread, the callback runs there and
races with main-thread teardown — a cross-thread data race or use-after-free.

## Example

```zig
// BUG: cleanup runs on any thread that triggers exit,
// but accesses self.context without a thread guard.
fn cleanup(self: *Self) void {
    self.context.deinit();  // BUG: may race if called from a worker thread
    self.handle = null;
}

pub fn init(self: *Self) void {
    add_exit_callback(cleanup);  // registered here — fires at process exit
}

// FIX: guard with a thread check before accessing main-thread state.
fn cleanup(self: *Self) void {
    if (!is_main_thread()) return;
    self.context.deinit();
    self.handle = null;
}
```

Real-world instance: oven-sh/bun#31376, where a callback registered via
`add_exit_callback` accessed mutable state without a main-thread guard,
causing a data race when exit was triggered from a worker thread.

## When this might be a false positive

- **Thread-safe callback**: if the registered function only accesses
  immutable data or uses its own synchronization, the missing guard is fine.

- **Always-main-thread exit**: if the process always exits from the main
  thread in practice, the race cannot occur.  Adding the guard is still
  a safety improvement.

- **Out-of-file callback**: if the registered function is defined in a
  different file, the rule cannot inspect its body and won't fire.

To suppress on a specific line, add a `// zbc-disable-line:exit-callback-cross-thread` comment.
