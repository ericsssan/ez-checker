# ref-before-ownership-transfer

A refcounted object `<x>` has its refcount incremented via `<x>.ref()`
(or `.retain()` / `.reference()` / `.addRef()`) and is then immediately
passed as the **first argument** to an `init`-style constructor that takes
ownership.  The `init` call stores `<x>` and will decrement the refcount
exactly once on cleanup.  The extra ref bumped by the caller is never
balanced — the object's refcount never reaches zero and the object leaks.

## Example

Incorrect — `query.ref()` over-increments the refcount before handing
ownership to `MySQLQuery.init`, which already manages the lifecycle:

    query.ref();
    const mysql_query = MySQLQuery.init(query, allocator, options);
    // MySQLQuery will call query.deref() once on cleanup.
    // The extra .ref() is never balanced → query leaks.

Fix — remove the extra `.ref()`:

    const mysql_query = MySQLQuery.init(query, allocator, options);

Or, if the caller genuinely needs to keep its own reference, release it
explicitly when done:

    query.ref();
    const mysql_query = MySQLQuery.init(query, allocator, options);
    defer query.deref();   // balance the caller's ref

## When this might be a false positive

- The `init` function does NOT take ownership (doesn't store `<x>` or
  call release on it).  This is uncommon in Zig idiom — `Type.init(x,…)`
  conventionally establishes ownership — but possible in adapters or
  wrappers.  Silence with `defer <recv>.deref()` or `defer <recv>.release()`.
- The refcount model requires the caller to hold a reference AND the init
  also holds one (dual ownership).  In that case, add the paired
  `defer <recv>.deref()` so the intent is explicit and the diagnostic clears.

## Related

- `unreleased-refs-on-error`: addref in a loop without `errdefer` release —
  the error-path leak complement to this rule's success-path leak.
- `heap-leak`: object whose destructor never frees `self` — different leak
  class, but same "never reaches zero" outcome.
