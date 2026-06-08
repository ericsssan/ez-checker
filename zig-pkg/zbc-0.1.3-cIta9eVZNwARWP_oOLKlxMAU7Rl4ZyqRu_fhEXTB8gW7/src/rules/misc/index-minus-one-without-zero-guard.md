# index-minus-one-without-zero-guard

**Severity:** error  
**Category:** misc / bounds  
**Tier:** 1 (token walk)

## What this checks

`buf[idx - 1]` where the subtraction `idx - 1` is not guarded against
`idx == 0`.  When `idx` is a `usize` (or any unsigned integer) and equals
zero, `idx - 1` wraps to `maxInt(usize)`, producing an out-of-bounds
index that panics in Debug/Safe builds or reads arbitrary memory in
ReleaseFast.

## Example (fires)

```zig
// BUG: pi could be 0; pi - 1 wraps to maxInt(usize)
if (npa_str[pi - 1] != '/') { ... }

// BUG: self.current could be 0; current - 1 is OOB
return self.items[self.current - 1];
```

## Fix

Add a zero-guard before the subtraction:

```zig
if (pi == 0 or npa_str[pi - 1] != '/') { ... }

// Or restructure:
if (self.current > 0) return self.items[self.current - 1];
```

## Real-world instances

- oven-sh/bun#24561 — `src/install/hosted_git_info.zig`:
  `npa_str[pi - 1] != '/'` where `pi` is the payload of an optional that
  could be `0`; fix added `pi == 0 or` before the comparison.
- oven-sh/bun#28487 — `src/shell/braces.zig`:
  `return self.prev()` where `prev()` accesses `self.items[self.current - 1]`
  and `self.current` could be `0`; fix became
  `return if (self.current > 0) self.prev() else self.peek()`.
