# self-pointer-in-returned-value

`<local>.<field> = &<local>;` then `return <local>;` — the
self-referential struct is COPIED on return; the field still
holds the original stack address, which is invalid both during
and after the copy.  Even when the caller stores the returned
value into another `var`, the field points at a now-dead frame.

## Shape

```zig
const Node = struct {
    val: u32,
    self: ?*Node = null,
};

pub fn make() Node {                   // returns BY VALUE
    var n = Node{ .val = 5 };
    n.self = &n;                       // ← &n is THIS frame's address
    return n;                          // n is copied to caller; the copy's
                                       //   .self still points at our dead frame
}
```

When the caller writes `var owned = make();`, `owned.self`
points at `make`'s stack frame, which has been reclaimed.
Subsequent `owned.self.?.val` reads dangling memory.

## Detection

Per-fn token walk:
1. Skip comptime type-builder fns.
2. Find `<id> . <field> = & <id> ;` where BOTH `<id>` references
   are the same single identifier — the canonical self-borrow.
3. Verify the identifier names a fn-local (not a parameter — a
   parameter's frame outlives the call; `&<param>` is caller
   storage, not stack escape).
4. Find a subsequent bare `return <id>;` of the SAME local.
5. Fire at the self-borrow assignment with a note pointing at
   the return site.

## Why this isn't already caught

The existing `stack-escape` rule catches:
- `return &<local>;` — direct address-of return.
- `out.<field> = &<local>;` through a `*T` parameter — write-through.

This rule targets a different shape: returning the LOCAL ITSELF
by value, where the local's own field carries a self-borrow.
The borrow doesn't appear at the return expression (just `return
n;` is bare), so stack-escape's composite-borrow tracking
doesn't reach it.

## Fix patterns

```zig
// Heap-allocate so identity is stable:
pub fn make(alloc: std.mem.Allocator) !*Node {
    const n = try alloc.create(Node);
    n.* = .{ .val = 5 };
    n.self = n;                        // n is already a heap *Node
    return n;
}

// Or set the self-pointer AFTER the move, in a separate step:
pub fn make() Node { return .{ .val = 5 }; }
pub fn bind(n: *Node) void { n.self = n; }
// caller: var owned = make(); bind(&owned);
```

## Coverage limits

Conservative — requires:
- LHS and RHS receivers to be the same single identifier
  (no chains like `<x>.field.subfield = &<x>`).
- Bare `return <local>;` (no wrapper-call returns, no `return .{
  ...local...}` struct-literal returns).
- The local to be in the file's local-binding table (not a
  param).

Real-world: common when porting C / Rust intrusive
self-pointer structures.  Zig's value semantics make this
silently wrong even when the source language version was
correct (Rust's `Pin`, C's manual address arithmetic).
