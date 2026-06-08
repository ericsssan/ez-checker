# stack-fallback-escape

`std.heap.stackFallback(N, <inner_alloc>)` returns an allocator
whose first `N` bytes of allocation come from a buffer in the
*caller's* stack frame.  Calls that stay under the threshold get
fast, stack-resident memory; calls over the threshold fall through
to `<inner_alloc>`.

When a container built on the fallback allocator's `.get()`
result calls `.toOwnedSlice()` / `.toOwnedSliceSentinel()` / a
similar value-yielding method, the returned slice points into
that caller-stack buffer — for the small-allocation path.  If
that slice escapes the function (returned, stored in a non-local
struct, written through an out-pointer), the pointer dangles the
moment the frame dies.  Reading from it later is undefined
behavior: it passes locally when the data fits in the stack
buffer, then explodes in production with payloads that happen to
stay under `N`.

The fix is to copy the value onto the inner allocator (which IS
heap-backed and outlives the frame) before letting it escape:

    const tmp = try cmd.toOwnedSlice();
    return .{ .shell = try alloc.dupeZ(u8, tmp) };

## Example

Incorrect — `cmd` is built on `stack_fallback.get()`, the
`toOwnedSlice` result is the stack buffer, and `return` lets it
escape:

    fn setupBash(alloc: std.mem.Allocator, ...) !Shell {
        var stack_fallback = std.heap.stackFallback(4096, alloc);
        var cmd = ShellCommandBuilder.init(stack_fallback.get());
        defer cmd.deinit();
        // … cmd.append(...) ...
        return .{ .shell = try cmd.toOwnedSlice() };   // ← UAF
    }

Fix — copy through the real allocator before returning:

    fn setupBash(alloc: std.mem.Allocator, ...) !Shell {
        var stack_fallback = std.heap.stackFallback(4096, alloc);
        var cmd = ShellCommandBuilder.init(stack_fallback.get());
        defer cmd.deinit();
        // …
        const cmd_str = try cmd.toOwnedSlice();
        return .{ .shell = try alloc.dupeZ(u8, cmd_str) };
    }

## When this might be a false positive

- The container's value-yielding method makes its own copy onto
  a different allocator internally.  Rare — `toOwnedSlice` and
  friends are conventionally zero-copy.
- The fallback threshold `N` is set high enough that the
  allocation never lands in the stack buffer in production
  (e.g. `N = 0`).  In that case the fallback is a no-op and the
  pattern degenerates to using `<inner_alloc>` directly; the
  rule should ideally suppress when `N == 0`.

## Related

- `stack-escape`: the broader case of returning `&local` or a
  pointer into a function-local stack variable.  This rule is the
  *allocator-handed-out* variant — same UAF, different surface.
- `arena-escape`: returning a value borrowed from a function-local
  arena.  Same lifetime story (allocator dies with frame).
