# defer-and-errdefer-free-overlap

`defer <alloc>.free(<X>);` (unconditional cleanup) AND an
`errdefer { ... <lhs> = <X>; ... }` block (error path: write `<X>`
into a field) AND a subsequent `try`.  On the error path:

1. `errdefer` fires: frees the NEW value (`self.<field>`), then
   sets `self.<field> = <X>` (the OLD value, to-be-freed).
2. `defer` fires: frees `<X>`.

`self.<field>` is now a dangling pointer to freed memory.

## Canonical bug (ghostty-org/ghostty#8249 — `Atlas.grow`)

```zig
const data_old = self.data;
self.data = try alloc.alloc(u8, new_size);
defer alloc.free(data_old);              // unconditional: frees OLD
errdefer {
    alloc.free(self.data);                // on error: frees NEW
    self.data = data_old;                 // …then "restores" OLD
}
try self.nodes.append(alloc, ...);        // can fail → both fire
// On failure: errdefer sets self.data = data_old; defer frees
// data_old; self.data dangles.
```

## Fix

Move the OLD-value free into the errdefer's success path, or
restructure so the swap is atomic:

```zig
const data_old = self.data;
self.data = try alloc.alloc(u8, new_size);
errdefer {
    alloc.free(self.data);
    self.data = data_old;
}
try self.nodes.append(alloc, ...);
alloc.free(data_old);                     // only on success
```

## Why the detector is precise

- Requires three signals simultaneously:
  1. `defer <alloc>.free(<X>);` somewhere in the fn.
  2. `errdefer { ... }` BLOCK (inline form excluded — too varied)
     that contains both:
     - An assignment `<lhs> = <X>` where `<X>` matches a
       deferred name.
     - A free/destroy call.
  3. A `try` after the errdefer (the fallible op).
- Without the assignment in errdefer, it's a plain unconditional
  cleanup (no resurrection).
- Without the free in errdefer, it's just a state restore (no
  swap).
- Without the later `try`, neither defer nor errdefer fire in a
  combined way.

## Limitations (deliberate)

- Inline `errdefer <single-stmt>;` is not matched — the
  swap-and-restore pattern always needs at least two statements,
  so it's a block form.
- Doesn't track aliased restores (`const tmp = data_old; errdefer
  ... = tmp;`).
