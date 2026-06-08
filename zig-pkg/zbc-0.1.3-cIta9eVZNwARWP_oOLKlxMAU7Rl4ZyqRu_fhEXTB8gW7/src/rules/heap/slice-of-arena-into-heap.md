# slice-of-arena-into-heap

A slice allocated through a function-local
`std.heap.ArenaAllocator` is passed as data to a container method
(`append`, `appendSlice`, `put`, `insert`, etc.) whose allocator
argument is NOT the arena's allocator.  When the arena dies at
scope exit (typically via `defer arena.deinit()`), the container
is left holding a dangling slice into freed memory.

## Why this matters

Arena allocators are commonly used as per-call scratch — a fresh
arena is created at fn entry, used for intermediate state, then
torn down at fn exit.  Any data that needs to live BEYOND the
fn's lifetime must be copied out via the long-lived allocator
(usually `self.gpa`), not stored by reference.

The bug is *invisible*: the arena-allocated slice is valid at the
moment of the store, the container's `appendSlice` succeeds, the
fn returns successfully.  Only when the caller later reads from
the container does the dangling read fire — and the symptom
points at the *consumer*, not at the *producer* where the bug
lives.

This rule complements zbc's existing arena-tracking:
- `arena-escape` catches escape via `return`.
- `arena-use-after-kill` catches reads after the arena's `deinit`
  in the same fn.
- This rule catches the third escape path: STORE into a
  longer-lived container *during* the arena's lifetime.

## Canonical bug

```zig
pub fn parse(self: *Parser, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const tokens = try tokenize(arena_alloc, input);     // arena-owned
    try self.token_cache.appendSlice(self.gpa, tokens);  // ← stored into
                                                          //   heap container
}
// `arena.deinit()` fires here → self.token_cache now holds
// dangling slices.  Next read of `token_cache.items[i]` is UAF.
```

## Fix

Copy the data with the destination's allocator before storing:

```zig
const tokens = try tokenize(arena_alloc, input);
const owned = try self.gpa.dupe(Token, tokens);
try self.token_cache.appendSlice(self.gpa, owned);
```

Or skip the arena entirely if everything ends up in the long-lived
container anyway:

```zig
const tokens = try tokenize(self.gpa, input);
try self.token_cache.appendSlice(self.gpa, tokens);
```

## Why the detector is precise

Four-pass token-walk per fn:

1. **Find arena vars** — `var <A> = ... ArenaAllocator.init(...)`.
   Without an arena in the fn, the rule does no work.
2. **Find allocator handles** — `const <H> = <A>.allocator();`
   binds `<H>` as an alias for `<A>.allocator()`.
3. **Find arena-allocated slices** — `const <X> = try <H>.alloc(...)`
   or `const <X> = try <A>.allocator().<alloc-method>(...)` inline.
4. **Find heap stores** — `<C>.<store-method>(<allocator>, ..., <X>)`
   where `<allocator>` is NOT the arena's (not `<H>`, not
   `<A>.allocator()`).

The "first arg is the arena allocator" check is the rule's main
precision lever — storing into a SUB-CONTAINER of the same arena
is fine (`sub_list.appendSlice(arena_alloc, tokens)`).

Limitations (deliberate, kept narrow for first cut):
- Only catches arena allocators bound through `arena.allocator()`
  one hop — multi-hop aliasing (`const a = h; const b = a;`) is
  out of scope.
- Only checks the call's *first* argument as the allocator slot
  — Unmanaged-style APIs.  Managed containers
  (`var list = std.ArrayList(T).init(alloc); try list.append(x);`)
  store the allocator internally and we can't tell from the
  call site what allocator they use; this rule won't catch
  stores into them.
- Container store-method allowlist is narrow: append /
  appendSlice / appendNTimes / insert / insertSlice / put /
  putAssumeCapacity / putNoClobber / addOne / addManyAsSlice.
