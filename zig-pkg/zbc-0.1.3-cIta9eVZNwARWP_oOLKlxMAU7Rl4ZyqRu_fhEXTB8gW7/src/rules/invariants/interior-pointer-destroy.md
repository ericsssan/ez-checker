# interior-pointer-destroy

Calling a method that destroys its receiver (`allocator.destroy(self)`
or `allocator.free(self)` in the body) on a pointer that is NOT the
result of `allocator.create()` is undefined behavior.  The most
common shape: a for-loop captures into a container by-pointer
(`for (entries.items) |*r|`), then calls a destructor-shape method
on that interior pointer.  The allocator never returned that
pointer, so passing it to `destroy` corrupts allocator metadata or
frees an unrelated allocation.

zbc fires only when inference proves the method takes ownership of
its receiver — i.e. the method's body literally calls
`<allocator>.destroy(self)` or `<allocator>.free(self)`.  Methods
named `deinit` / `close` / `deref` / `release` / etc. that merely
release sub-fields are NOT flagged: they're safe to call on interior
pointers because the container still owns the backing storage.

Cross-module destructors (callee defined in another file) are not
inferred and so don't fire today.  This is a deliberate trade-off:
firing on name alone produced ~200 false positives on real codebases
(refcount `deref()`, allocator-arg `deinit(alloc)`, etc.), drowning
out any real signal.

## Example

Incorrect — `result` is a pointer INTO `entries.items`, not a fresh
allocation, AND `Entry.destroy` calls `gpa.destroy(self)`:

    const Entry = struct {
        pub fn destroy(self: *Entry, gpa: std.mem.Allocator) void {
            gpa.destroy(self);  // ← inferred: takes ownership(self)
        }
    };

    for (entries.items) |*result| {
        result.destroy(gpa);    // ← UB; interior pointer
    }
    entries.deinit();           // ← may then double-free

Fix — let the container own the lifecycle:

    for (entries.items) |result| {
        // Consume the element's fields directly; let entries.deinit
        // clean up the backing storage.
    }
    entries.deinit();

## When this might be a false positive

- The destructor IS the canonical `allocator.destroy(self)` shape but
  the call site passes an interior pointer intentionally because the
  container is being torn down element-by-element and the allocator
  was constructed to track per-element slots.  Suppress with
  `// zbc-disable-line:interior-pointer-destroy`.

## Related

- `heap-double-free`: the typical follow-on when interior-pointer
  destroy frees a container's backing and then the container
  later deinits.
