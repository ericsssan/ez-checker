# overwrite-without-deinit

A heap-owning struct field is overwritten via single-field
assignment (`this.field = <RHS>;`) without first calling the
field's destructor (`this.field.deinit()` / `.deref()` /
`<allocator>.free(this.field)`).  Each reassignment leaks the
prior value — the old object's heap descriptor is unreachable
and never freed.

This is the single-field counterpart to `clobbered-by-struct-reset`
(whole-struct `this.* = T{…}` overwrites).  The shape is dominant
in protocol decoders, re-execute paths, redirect handlers, and
"last-value-wins" state fields.

## Example

Incorrect — MySQL's `checkForDuplicateFields` re-uses
`field.name_or_index` (a `NameOrIndex` union with a `deinit`)
across rows; on a duplicate, the prior allocation is overwritten:

    if (seen.found_existing) {
        field.name_or_index = .duplicate;   // ← leaks old name
    }

Fix:

    if (seen.found_existing) {
        field.name_or_index.deinit();
        field.name_or_index = .duplicate;
    }

## When this might be a false positive

- The assignment is a first-time set in an `init` / `create` /
  `new` / `from*` constructor where the receiver was just minted
  by `allocator.create(T)` (so the prior field state is the
  declared default — nothing to free).  The rule skips fns whose
  name is in the constructor allowlist.
- The cleanup is delegated to a helper called immediately
  beforehand (`this.clearOldField();` then `this.field = X;`).
  zbc doesn't follow the helper.  Either inline the cleanup or
  rename the helper to include `deinit` so the token scan picks
  it up.
- The RHS is `.duplicate` / `.empty` / a known sentinel variant
  that explicitly represents "no longer owned" — the prior
  value is still leaked, but the new value's deinit is a no-op.
  Adding the explicit `<field>.deinit();` before the assignment
  documents the intent and removes the diagnostic.

## Related

- `clobbered-by-struct-reset`: whole-struct overwrite that drops
  a previously-assigned field.  Same leak class, different syntax.
- `heap-leak`: type-level version (destructor doesn't free `self`).
- `asymmetric-field-free`: when sibling fields with the same type
  are partially freed in `deinit`.
