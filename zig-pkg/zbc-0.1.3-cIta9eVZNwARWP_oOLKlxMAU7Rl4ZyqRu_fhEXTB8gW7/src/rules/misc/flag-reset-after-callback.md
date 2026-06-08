# flag-reset-after-callback

A boolean flag whose name contains `in_progress` (e.g. `write_in_progress`,
`read_in_progress`, `flush_in_progress`) is set to `true`, a method call is
made that may re-entrantly set the flag to `true` again, and then the flag is
unconditionally reset to `false` — clobbering the re-entrant update.

## Example

```zig
// BUG: `write_in_progress` is cleared AFTER the error callback.
// If `emitError` triggers re-entrant code that calls write() again,
// write() sets `write_in_progress = true`, but the line below then
// clobbers it to `false`. Cleanup code then sees write_in_progress=false
// and frees the native state while the re-entrant write is still running.
pub fn onWriteError(this: *Self, err: anyerror) void {
    this.write_in_progress = true;   // set earlier in the function
    // ...
    this.emitError(err);             // may re-enter and set write_in_progress=true
    this.write_in_progress = false;  // BUG: clobbers re-entrant setting
}

// FIX: clear the flag BEFORE invoking the callback:
pub fn onWriteError(this: *Self, err: anyerror) void {
    this.write_in_progress = true;
    // ...
    this.write_in_progress = false;  // clear BEFORE the call
    this.emitError(err);
}
```

The canonical instance of this bug is oven-sh/bun#29899, where
`this.write_in_progress = false` appeared after `this.emitError(err)`.
If `emitError` triggers a re-entrant `write()`, that write sets
`write_in_progress = true`; the line after the callback immediately
clobbers it back to `false`, so the subsequent cleanup frees native state
while the second write is still in flight — a use-after-free.

## When this might be a false positive

- **Provably non-reentrant callbacks**: if the method called between the
  `= true` and `= false` statements is known at compile time to be
  synchronous and cannot call back into the current function, the
  clobbering is benign. This most commonly arises in simple utility
  functions where `doSomething()` has no path back to the caller.

- **Intentional reset after error path**: sometimes the `= false` after an
  error callback is intentional — the function wants to signal that the
  operation is no longer in progress even after the error handler fires.
  In that case the fix (clear before the call) may change observable
  behavior; verify that the callback cannot re-enter before applying it.

To suppress on a specific line, add a `// zbc-disable-line:flag-reset-after-callback` comment:

```zig
this.write_in_progress = false;  // zbc-disable-line:flag-reset-after-callback
this.emitError(err);
```
