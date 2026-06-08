# heap-leak

A type heap-allocates instances of itself (`allocator.create(Self)`)
but its destructor — `finalize` / `deinit` / `destroy` — never
calls `allocator.destroy(self)`.  Every instance is leaked: the
backing memory is reachable only through the heap pointer, and
nothing frees it.

This is the cross-method leak that per-fn analysis would normally
miss.  zbc detects it by inferring that the type is heap-self-
allocating from any constructor's body, then checking the
destructor's body for the missing `destroy(self)` call.

## Example

Incorrect — `ResolveMessage` is heap-allocated by `create()` but
`finalize()` only frees a sub-field, leaving `self` itself
leaked:

    const ResolveMessage = struct {
        allocator: std.mem.Allocator,
        msg: []u8,

        pub fn create(alloc: std.mem.Allocator, msg: []u8) *ResolveMessage {
            const this = alloc.create(ResolveMessage) catch unreachable;
            this.* = .{ .allocator = alloc, .msg = msg };
            return this;
        }

        pub fn finalize(self: *ResolveMessage) void {
            self.allocator.free(self.msg);
            // ← missing: self.allocator.destroy(self);
        }
    };

Fix — destructor must release the heap descriptor too:

    pub fn finalize(self: *ResolveMessage) void {
        self.allocator.free(self.msg);
        self.allocator.destroy(self);
    }

## When this might be a false positive

- The destructor passes ownership of `self` to another fn that
  zbc can't see (FFI boundary, GC handoff, callback registration).
  Rename the method out of `finalize` / `deinit` / `destroy` to
  signal that, or add a wrapper that explicitly handles `self`'s
  lifecycle.
- The type is heap-allocated only in tests or rare paths; the
  canonical instance is value-typed and stored by-value.  In that
  case, rename the heap-allocating method out of `create` /
  `init` / `new` so it doesn't look like the canonical constructor.

## Related

- `heap-use-after-free`: the typical follow-on bug when the
  unfreed heap descriptor is later reached through a stale
  reference.
- `allocator-mismatch`: when the destructor frees with a
  different allocator than the one that allocated.
