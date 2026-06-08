# maybe-assert-panics

`someCall(...).assert()` — chaining `.assert()` on the result of a fallible call converts every OS error into a process-crashing panic. In bun's codebase, `bun.sys.Maybe(T).assert()` unpacks the result value or calls `bun.Output.panic(...)` when the variant is `.err`.

## What the rule checks

The rule fires on the 5-token pattern `) . assert ( )` — a method call result immediately chained with `.assert()`. The preceding `)` distinguishes chained calls (`someCall().assert()`) from bare field access (`maybe.assert()`).

It does not fire on `bun.assert(cond)` (a static function call), which has the shape `identifier . identifier ( ` rather than `) . identifier ( `.

## Why it matters

`Maybe(T).assert()` is a convenience that works for infallible code paths (like allocations that panic on OOM). When used on I/O operations (pipe start, socket operations, file opens), it silently converts every OS error into a panic.

OS errors from I/O operations are expected and recoverable: `UV_ENOTCONN`, `UV_EPIPE`, `UV_ENOENT`, etc. Panicking on these instead of propagating an error:
1. Crashes the entire bun process for a single connection's error
2. Provides no opportunity for cleanup (open handles, in-flight requests)
3. Turns a recoverable condition into a denial-of-service vector

## Real-world instances

- **oven-sh/bun#23344**: `subprocess.stdin.buffer.start().assert()` panicked when libuv returned `UV_ENOTCONN` after the Windows long-path CWD workaround was applied.
- **oven-sh/bun#23520, #23935**: identical pattern in stdout and stderr pipe start paths.

## Fix

```zig
// Instead of:
proc.stdin.buffer.start().assert();

// Check the result and propagate:
const start_result = proc.stdin.buffer.start();
if (start_result == .err) {
    return start_result.err;
}
```
