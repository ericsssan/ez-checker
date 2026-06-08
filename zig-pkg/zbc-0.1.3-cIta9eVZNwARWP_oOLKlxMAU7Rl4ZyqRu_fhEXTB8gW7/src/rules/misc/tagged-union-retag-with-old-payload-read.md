# tagged-union-retag-with-old-payload-read

An assignment of the shape `<path> = .{ .<NewTag> = .{ ... <path>.<OldTag>... ... } };`
reads the OLD tag's payload while assigning a NEW tag to the same
union.  Under Zig's x86_64 self-hosted backend (post-0.15) the
active-tag flip happens BEFORE the RHS evaluates, so the read of the
old payload may see undefined / garbage.  LLVM hid this issue for
years on aarch64 / x86_64-via-LLVM.

## Why this matters

Tagged unions in Zig are represented as `{ tag, payload }`.  Writing
`x = .{ .NewTag = init }` requires the compiler to:

1. Write the new tag (`tag = .NewTag`).
2. Evaluate `init`.
3. Write the payload (`payload = init`).

If `init` reads from `x` itself (or any path through it), the read
happens AFTER step 1.  Under aliasing-aware backends, the old tag's
payload memory may already be reinterpreted as the new tag's
payload — the bytes are undefined.

The buggy code typically looks correct because LLVM and earlier Zig
backends evaluated the RHS *before* writing the LHS, hiding the
problem.  The Zig 0.15 x86_64 self-hosted backend changed this; PRs
fixing the same shape in the same file have appeared 14 months apart
in TigerBeetle alone, suggesting the pattern recurs whenever
authors aren't aware.

## Canonical bug (tigerbeetle/tigerbeetle#3317, #2200)

```zig
self.state = .{
    .iterating = .{
        .key_exclusive_next = self.state.loading_index.key_exclusive_next,
        .values = .none,
    },
};
```

`self.state` is being assigned a new tag (`.iterating`); inside, the
RHS reads `self.state.loading_index.key_exclusive_next` — the OLD
tag.  On x86_64 self-hosted the `loading_index` payload is undefined
by the time the read evaluates.

## Fix

Hoist the read into a local before the union assignment:

```zig
self.state = iterating: {
    const key = self.state.loading_index.key_exclusive_next;
    break :iterating .{ .iterating = .{ .key_exclusive_next = key, .values = .none } };
};
```

Or simpler with a plain `const`:

```zig
const key = self.state.loading_index.key_exclusive_next;
self.state = .{ .iterating = .{ .key_exclusive_next = key, .values = .none } };
```

## Why the detector is precise

- The LHS path must be a chain of `<ident>.<ident>...` immediately
  preceding the `=`.  Multi-segment paths are supported (e.g.
  `self.foo.bar`).
- The RHS must start with the exact shape `.{ .<NewTag> = ...` —
  the canonical anonymous-struct-literal tag init.
- The old-tag access must use the EXACT same LHS path as a prefix,
  followed by `.<OldTag>` where `OldTag != NewTag`.
- Same-tag retag (`x = .{ .A = x.A.bump }`) is suppressed — that's
  field-update within the same variant; potentially also a backend
  hazard but less reliably so.
- Non-tag-shaped suffixes (`.len`, `.ptr`, `.items`, `.capacity`)
  are suppressed — those are slice/container field accesses, not
  union variants.
- The detector requires the LHS to be preceded by a statement
  boundary (`{`, `;`, `}`, `=>`, `return`, `|`) so partial
  expressions don't get misread as a full assignment.
