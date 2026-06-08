# forced-unwrap-iterator-next

**Severity:** error  
**Category:** misc / panic  
**Tier:** 1 (token walk)

## What this checks

`.next().?` force-unwraps the result of an iterator's `next()` call.
Standard Zig iterators return `?T`, where `null` means the iterator is
exhausted.  Force-unwrapping with `.?` asserts at runtime that a value is
present.  When the iterator is already exhausted — e.g., the caller passed
fewer items than the function expects — this panics in Debug/ReleaseSafe
and invokes undefined behaviour in ReleaseFast.

## Example (fires)

```zig
fn processSeq(iter: *ArgIterator) u32 {
    const first = iter.next().?;   // panics if iter is already empty
    const second = iter.next().?;  // panics if only one argument was given
    return first + second;
}
```

## Fix

Use `orelse` to handle exhaustion gracefully:

```zig
fn processSeq(iter: *ArgIterator) !u32 {
    const first = iter.next() orelse return error.MissingArgument;
    const second = iter.next() orelse return error.MissingArgument;
    return first + second;
}
```

Or the loop form when the count is not fixed:

```zig
while (iter.next()) |val| {
    process(val);
}
```

## Real-world instances

- oven-sh/bun#27415 — `seq` builtin called `.next().?` after consuming all
  flag arguments; when only flags were provided (no numeric args) the
  iterator was empty → unconditional panic.
- oven-sh/bun#27316 — `cmds_array.next().?` on a JS-supplied command array;
  an empty array caused an unconditional panic before any work was done.
