# stack-escape

Returning a pointer or slice into a function-local stack variable.
The storage is reclaimed when the function returns, so the caller
reads garbage (or, worse, a future frame's contents).

## Example

Incorrect:

    fn build() *const [3]u8 {
        var buf: [3]u8 = .{ 1, 2, 3 };
        return &buf;                    // ← &buf dies with the frame
    }

Fix — return by value, or take an output buffer:

    fn build() [3]u8 {
        return .{ 1, 2, 3 };
    }

## When this might be a false positive

- The local is `comptime` (or used only in a `comptime`-instantiated
  function) and its address is comptime-known.  zbc does not track
  `comptime` evaluation; if the function only runs at compile time,
  the rule doesn't apply.  Split the function so the comptime form
  is its own decl, or restructure to return by value.
- The "stack local" is actually a function parameter passed by
  reference, where the caller owns the storage.  zbc treats params
  as `.plain` by default — if you see this rule fire on a param,
  please file an issue.

## Related

- `arena-escape`: returning a borrow into a function-local arena.
- `heap-use-after-free`: the storage was on the heap and has been
  explicitly freed.
