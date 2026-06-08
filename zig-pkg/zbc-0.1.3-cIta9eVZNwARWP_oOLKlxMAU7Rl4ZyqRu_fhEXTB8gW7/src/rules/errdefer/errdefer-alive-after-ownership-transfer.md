# errdefer-alive-after-ownership-transfer

**Severity:** error  
**Category:** errdefer / double-free  
**Tier:** 1 (token walk)

## What this checks

An `errdefer X.deinit()` (or `.deref`/`.free`/`.release`) remains armed
after a constructor-style call takes ownership of `X`, so a subsequent
`try` in the same scope triggers the errdefer and double-frees `X`.

## Example (fires)

```zig
fn buildS3File(global: *JSGlobal, args: *Args) !JSValue {
    const path = try PathLike.fromJS(global, args);
    errdefer path.deinit();                        // ← armed here

    // constructS3File takes ownership of `path` — it will free `path` on its own path
    const blob = try constructS3File(global, path);
    _ = blob;

    try doMoreWork();     // ← BUG: if this throws, errdefer fires
                          //   path.deinit() called on already-owned path → double-free
    return .undefined;
}
```

## Fix

After the ownership-taking call, reset `X` to an inert sentinel to disarm
the errdefer:

```zig
const blob = try constructS3File(global, path);
path = .{};   // ← disarms the errdefer — path is now "empty"
try doMoreWork();  // safe: errdefer fires on empty path, which is a no-op
```

## Real-world instances

This pattern appeared in 8 bun PRs:

- oven-sh/bun#28495, #28592, #29081, #29643, #29656, #30169, #30437, #30465

All fixed `PathLike`, `S3File`, `Blob`, and CSS-parser constructors that
took ownership of a `PathLike` or `JSValue.Strong` handle without the
caller disarming the `errdefer` that was still registered.
