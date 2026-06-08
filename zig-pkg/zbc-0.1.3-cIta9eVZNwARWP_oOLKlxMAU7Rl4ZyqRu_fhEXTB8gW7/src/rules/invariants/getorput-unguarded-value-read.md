# getorput-unguarded-value-read

`map.getOrPut(key)` returns a `GetOrPutResult` with two fields:
`found_existing` (bool) and `value_ptr` (pointer to the slot).  When
`found_existing == false` a new slot was inserted and `value_ptr.*` is
**uninitialised** — reading it is undefined behaviour.

## Example

Incorrect:

    const gop = try map.getOrPut(key);
    gop.value_ptr.* += 1;              // ← UB when key is new

Fix — guard the read behind the `found_existing` check:

    const gop = try map.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;

Or initialise before increment:

    const gop = try map.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
    } else {
        gop.value_ptr.* += 1;
    }

## What is flagged

- Any read of `<gop>.value_ptr.*` (including compound assignments
  `+= -= |=` etc.) before a reference to `<gop>.found_existing`.
- A plain `<gop>.value_ptr.* = <expr>;` (write-only) is safe and
  is NOT flagged.

## When this might be a false positive

If the caller guarantees the key pre-exists (e.g. via a prior
`map.contains(key)` check or structural invariant), `found_existing`
is always `true` at the call site.  The rule can't see that guarantee
and will still fire.  Either add an explicit `assert(gop.found_existing)`
to document the invariant, or refactor to use `map.getPtr(key).?` which
is explicit about assuming the key exists.

## Related

- **hashmap-getptr-rehash** — use of a `getPtr` result after a
  rehashing mutation.
- **hashmap-iter-mutation** — mutating a HashMap while iterating it.
