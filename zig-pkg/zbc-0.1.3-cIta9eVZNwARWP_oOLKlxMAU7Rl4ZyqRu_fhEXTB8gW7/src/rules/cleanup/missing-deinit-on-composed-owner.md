# missing-deinit-on-composed-owner

A struct `Outer` exposes `pub fn deinit(...)`.  One of its fields
has a TYPE that's a struct in the same file ALSO exposing a
cleanup method (`deinit` / `close` / `destroy` / `free` / `stop` /
`finalize`).  But `Outer.deinit` doesn't call
`<self>.<field>.<cleanup>(...)` — the inner's owned non-memory
resources (file handles, sockets, mmaps, refs) leak.

## Why this matters

Unlike heap memory leaks (which the allocator's leak-check can
catch in tests), non-memory resources like OS file handles or
network sockets aren't tracked by the standard memory model.  A
forgotten `inner.deinit()` in the outer's destructor means:
- The OS handle stays open
- On Linux, `/proc/$pid/fd` grows
- Eventually hits the file-descriptor RLIMIT
- The process starts failing `open()` with EMFILE — far from the
  cause

ziglang/zig#22683 (`debug.StackIterator`) had to ADD
`MemoryAccessor.deinit` first — the inner type didn't even expose
one yet.  The fact that this pattern appeared in std debug code,
unnoticed, suggests it's widely under-detected.

## Canonical bug (ziglang/zig#22683)

```zig
const MemoryAccessor = struct {
    file: std.fs.File,            // /proc/self/mem
    pub fn init() MemoryAccessor { ... }
    pub fn deinit(ma: *MemoryAccessor) void {
        ma.file.close();
    }
};

const StackIterator = struct {
    ma: MemoryAccessor,
    // ... other fields ...

    pub fn deinit(it: *StackIterator) void {
        // BUG: forgot `it.ma.deinit();`
        // → /proc/self/mem file descriptor leaked
    }
};
```

## Fix

```zig
pub fn deinit(it: *StackIterator) void {
    it.ma.deinit();
}
```

## Why the detector is precise

- **Two-pass file analysis** — first pass collects all struct types
  in the file that expose a cleanup method (deinit/close/destroy/
  free/stop/finalize); second pass checks each outer struct's
  deinit body against its fields.
- **Type-name resolution** peels off `?`, `*`, `[...]` prefixes
  to get the underlying type name.  `?*Inner`, `[]Inner`,
  `?Inner` all resolve to `Inner`.
- **Cleanup-call match** accepts any cleanup-method name on
  the same receiver chain `<self>.<field>.<cleanup>(...)` —
  the outer doesn't have to call literally `.deinit()`; calling
  `.close()` or `.destroy()` on the field also counts.

## Limitations (deliberate)

- **Same-file types only** — types imported from other files
  aren't analyzed (would need cross-file resolution).  This
  means cross-module composition like `Outer.field: lib.Inner`
  is out of scope until zbc gets cross-file annotation support.
- **Borrow vs own** — the rule can't distinguish a field that
  OWNS its inner (must deinit) from one that BORROWS it (must
  not).  Heuristic: pointer-typed fields (`*Inner`) are
  TYPICALLY borrowed in Zig; non-pointer fields (`Inner`) are
  typically owned.  The rule still fires on `?*Inner` etc. —
  some FPs expected on actual borrows.
- **Conditional fields** — fields gated by `comptime` or
  build-flag may not need deinit on all platforms; the rule
  doesn't model this.
