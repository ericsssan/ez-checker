# ref-counted-copy-without-dupe

A struct literal field is initialised from the same-named field of
another struct (`.field = recv.field`) and the field name suggests it
holds a refcounted or heap-owned object (`name`, `str`, `string`, `ref`,
`handle`, `buf`, `data`, `content`), but no ref-acquire method
(`clone()`, `dupeRef()`, `ref()`, `retain()`, etc.) is called on the
source field in the surrounding code.

When both the source and the copy eventually call a destructor
(`deinit()` / `deref()` / `release()`), the shared underlying allocation
is decremented twice — the second decrement hits a zero-or-negative
refcount, causing a SIGFPE on refcount-assert builds or a use-after-free.

## Example

```zig
// BUG: `source.name` is an OwnedStringCell (refcounted).
// Copying it without calling clone()/dupeRef() means both `source`
// and `copy` share the same allocation.  When both are cleaned up,
// the refcount is decremented twice → SIGFPE.
const copy = Blob{
    .name = source.name,   // raw bitwise copy — BUG
    .size = source.size,
};

// FIX: acquire an extra reference so each side owns one decrement.
const copy = Blob{
    .name = source.name.clone(),   // +1 ref, balanced by copy's deinit
    .size = source.size,
};
```

The canonical instance of this bug is oven-sh/bun#30955, where
`Blob.name` (an `OwnedStringCell`) was bitwise-copied in a
`dupeWithContentType` path; when both the original and the copy were
freed, the second `name.deinit()` hit a `std.debug.assert(rc > 0)`
assertion → SIGFPE.

## When this might be a false positive

- **Plain value copy of a non-refcounted type**: a field named `data`
  or `buf` might simply hold a plain slice or integer — not a
  refcounted object.  If neither side calls a destructor on the field,
  the bitwise copy is safe.

- **Explicit ownership transfer**: if the copy is intentionally taking
  ownership without bumping the refcount (e.g. a `toOwned()` pattern
  that clears the source after copying), the rule fires spuriously.
  Suppress with a `// zbc-disable-line` comment.

To suppress on a specific line:

```zig
.name = source.name,  // zbc-disable-line:ref-counted-copy-without-dupe
```
