# catch-error-panic

`catch |err| @panic(...)` — catching a named error and immediately panicking turns a recoverable error into a process crash and prevents callers from handling it.

## What the rule checks

The rule fires on two patterns inside function bodies:

- **Form A**: `catch |err| @panic(...)`
- **Form B**: `catch |err| std.debug.panic(...)`

The key signal is that the programmer **named** the error variable (using `|err|` or `|_|`) — demonstrating awareness of the error — yet discarded it by crashing instead of returning it.

`catch unreachable` does not fire; that form is idiomatic in Zig for "this error is provably impossible" and is checked by the compiler in safe modes.

## Why it matters

In Zig, errors are values. The idiomatic way to handle an unexpected error is:

- `try call()` — propagate the error to the caller
- `call() catch unreachable` — assert the error cannot occur (safe-mode-verified)
- `call() catch |err| return err` — explicit re-return

`catch |err| @panic(...)` converts every instance of that error — including ones triggered by user-controlled inputs — into an unconditional process crash. For servers, this is a denial-of-service vulnerability.

## Real-world instance

**oven-sh/bun#30082** (S3 URL encoding): Four separate encode calls used a `var buff: [1024]u8 = undefined` output buffer and `catch |err| std.debug.panic(...)` on `error.BufferTooSmall`. S3 keys can be up to 1024 bytes, and percent-encoding can triple the output size, so any key over ~341 bytes would hit the panic in the server process.

Fix: size the buffer dynamically (`input.len * 3`) and use `try`.

## Fix

```zig
// Instead of:
encode(&buff, input) catch |err| @panic("encode failed: {}", .{err});

// Use try to propagate:
try encode(&buff, input);

// Or handle the specific error case:
encode(&buff, input) catch |err| switch (err) {
    error.BufferTooSmall => return error.InputTooLarge,
};
```
