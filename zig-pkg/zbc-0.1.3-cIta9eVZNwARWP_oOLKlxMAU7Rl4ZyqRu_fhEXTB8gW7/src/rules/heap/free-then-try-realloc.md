# free-then-try-realloc

A heap slice or pointer is freed and then immediately reassigned by
a fallible call (`X = try <allocator>.alloc(...)` or similar) with
no intervening sentinel write.  If the fallible call fails, the
function returns the error and `X` is left pointing at the freed
memory — a subsequent `deinit` (which expects `X` to be either
owned-and-valid or empty) frees the dangling pointer again,
double-freeing or reading freed memory.

The fix is to set `X = &.{};` (or `null` / `undefined` for the
appropriate type) between the free and the fallible call so that
the error path leaves `X` in a safe state.

## Example

Incorrect — `statement.columns` is freed then reassigned through a
`try`; on OOM, `deinit` later double-frees it:

    bun.default_allocator.free(statement.columns);
    statement.columns = try bun.default_allocator.alloc(
        ColumnDefinition41, header.field_count,
    );

Fix:

    bun.default_allocator.free(statement.columns);
    statement.columns = &.{};   // clear before the fallible alloc
    statement.columns = try bun.default_allocator.alloc(
        ColumnDefinition41, header.field_count,
    );

## When this might be a false positive

- The enclosing function's caller guarantees `deinit` won't be
  called on the half-initialized struct (uncommon — the safety
  contract is hard to enforce locally).  Adding the `X = &.{};`
  line is essentially free and removes the diagnostic.
- The fallible call is wrapped by `try` but the alloc itself
  cannot fail (e.g. `try alwaysSucceeds()`).  Rare; if you know
  the call is infallible, drop the `try`.

## Related

- `heap-double-free`: the downstream symptom — `deinit` re-frees
  the dangling pointer.
- `heap-use-after-free`: the other downstream symptom — any read
  of `X` after the failed realloc dereferences freed memory.
