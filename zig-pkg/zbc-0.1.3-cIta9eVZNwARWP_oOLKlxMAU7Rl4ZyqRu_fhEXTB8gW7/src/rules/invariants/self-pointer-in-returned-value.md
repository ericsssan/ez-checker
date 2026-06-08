# self-pointer-in-returned-value

`<local>.<field> = &<local>;` followed by `return <local>;` — the
struct is **copied** by value on return.  The field still holds the
address of the original stack slot, which is invalid after the copy
and also immediately after the function returns.

## Example

Incorrect:

    pub fn makeNode() Node {
        var node: Node = .{ .value = 42 };
        node.self_ptr = &node;    // ← address of stack slot
        return node;              // ← copies Node; field dangles
    }

Fix — either heap-allocate and return a pointer, or remove the
self-referential field:

    pub fn makeNode(allocator: Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{ .value = 42 };
        node.self_ptr = node;     // ← points at heap, stable
        return node;
    }

## When this might be a false positive

The rule only matches the exact `<ident>.<field> = &<ident>;` pattern
where both identifiers are the same local.  Chained field accesses
(`x.inner.ptr = &x.inner`) are not detected.

## Related

- **stack-escape** — returning a direct pointer to a local variable.
- **thread-spawn-local-pointer** — passing a local's address to a thread.
