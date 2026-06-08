# self-undefined-after-destroy

`<alloc>.destroy(<X>);` immediately followed by `<X>.* = ...;` or
`<X>.<field> = ...;` — the write goes through a now-dangling
pointer.

This is the inverted form of the canonical TigerStyle invariant:
**overwrite THEN free**.  The correct pattern poisons memory
*before* releasing it, so the freed allocation holds canary bytes
that catch use-after-free downstream:

```zig
// CORRECT — overwrite-then-free:
self.* = undefined;
allocator.destroy(self);

// BUG — free-then-overwrite:
allocator.destroy(self);
self.* = undefined;          // ← write to freed memory
```

The buggy form writes through a freed pointer.  Allocators with
quarantine / scribble / hardening (TigerBeetle's own arena,
ASAN, mimalloc's `MI_TRACK_ASAN`) will trap; on production
allocators the write silently corrupts another allocation that
happened to land at the same address.

## Why this matters

The TigerStyle invariant exists specifically because the inverted
order is invisible without sanitizers — and even with sanitizers,
the failure can be timing-dependent (depends on whether the
allocator reused the freed block before the stale write).  Code
review missed this exact bug in TigerBeetle's
`src/tigerbeetle/inspect.zig` (tigerbeetle/tigerbeetle#2687).

## Canonical bug (tigerbeetle/tigerbeetle#2687)

```zig
pub fn deinit(inspector: *Inspector) void {
    inspector.allocator.destroy(inspector);
    inspector.* = undefined;     // BUG: writes through a freed *Inspector
}
```

The fix is to swap the two lines:

```zig
pub fn deinit(inspector: *Inspector) void {
    inspector.* = undefined;
    inspector.allocator.destroy(inspector);
}
```

(But careful: this requires `inspector.allocator` to be read into
a local first if `.allocator` is a field of `inspector` — once
`inspector.* = undefined;` runs, `inspector.allocator` is also
undefined.)

## Why the detector is precise

- Pattern is tight: `<alloc>.destroy(<X>)` / `<alloc>.free(<X>)`
  with `<X>` as a bare identifier (not a chained access).
- Scan stops at:
  - Enclosing scope's closing `}`.
  - Reassignment of `<X>` (`<X> = ...`) — the name now points
    somewhere else.
- Skip the destroy if it's inside `defer` / `errdefer` — the
  destroy fires at scope exit, AFTER any in-fn-body writes.  Those
  writes happen first, with `<X>` still valid.
- Nested blocks are skipped — the write must be in the same
  block as the destroy for the lexical inversion to be a bug.
- Only `.destroy` / `.free` are recognized as the destroy ops
  (matches `std.mem.Allocator`'s API surface).
