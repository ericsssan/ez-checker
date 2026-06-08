# heap-double-free

Calling `free` or `destroy` on the same heap pointer more than once.
The second free either corrupts the allocator's bookkeeping or
aborts immediately, depending on the allocator implementation.

## Example

Incorrect — `buf` is freed on the error path by `errdefer` AND on
the success path explicitly:

    const buf = try allocator.alloc(u8, 32);
    errdefer allocator.free(buf);
    try process(buf);
    allocator.free(buf);                // errdefer also fires on
                                        // a later panic / try error

The errdefer fires whenever the enclosing function returns an
error — including errors thrown by code AFTER the explicit free —
producing a double-free if `buf` was already freed.

Fix — pick one ownership model.  Either let the errdefer be the
sole free for error paths and free explicitly on success, or
disarm the errdefer with a sentinel before freeing:

    const buf = try allocator.alloc(u8, 32);
    errdefer allocator.free(buf);
    try process(buf);
    allocator.free(buf);
    // ↑ safe here because no `try` follows; if there were a `try`
    // after this point, the errdefer would still be armed.

## When this might be a false positive

- Allocator-style methods (`obj.destroy(allocator)` where `destroy`
  is the struct method and `allocator` is the arg) used to be
  misclassified as `allocator.destroy(obj)`.  Fixed in commit
  `1286388`; if you see one, file an issue with the call shape.

## Related

- `heap-use-after-free`: reading the pointer after the (first) free.
