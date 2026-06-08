# slice-loop-reentrant-grow

A `for (<recv>.items)` loop captures the ArrayList's backing slice — its
`ptr` and `len` — at the start of iteration.  If any code inside the loop
body calls a function that **grows the same (or any) ArrayList** (via
`append`, `resize`, `ensureCapacity`, etc.), the backing buffer may be
reallocated.  After the reallocation the loop's captured `ptr` dangles
into freed memory; subsequent iterations access freed storage.

This is the re-entrant (callee-indirect) variant of the pattern.  Direct
same-function grows are caught by `arraylist-items-slice`.

## Example

Incorrect — `executePendingNapiModule` can append to `m_pendingNapiModules`
while the loop is iterating it:

    for (globalObject.m_pendingNapiModules.items) |mod| {
        executePendingNapiModule(globalObject, mod);
        // ^ may append to m_pendingNapiModules → realloc → items ptr dangles
    }

Fix — snapshot the count before the loop, or collect items into a
temporary list before processing:

    const pending = try arena.dupe(Module, globalObject.m_pendingNapiModules.items);
    globalObject.m_pendingNapiModules.clearRetainingCapacity();
    for (pending) |mod| {
        executePendingNapiModule(globalObject, mod);
    }

## When this might be a false positive

- The callee grows a **different** ArrayList than the one being iterated.
  zbc is conservative and fires whenever the callee `may_grow_collections`,
  regardless of which list it grows.  Suppress with
  `// zbc-disable-line:slice-loop-reentrant-grow` if you are certain
  the callee cannot grow the iterated collection.
- The ArrayList is **pre-allocated** (via `ensureTotalCapacity`) before the
  loop and the callee only calls `appendAssumeCapacity`-family methods (which
  cannot reallocate).  Those methods are excluded from `may_grow_collections`
  detection by design.

## Related

- `arraylist-items-slice`: same bug when the grow call is in the same
  function body (direct, not via a callee).
- `arraylist-element-ptr`: element pointer `&list.items[i]` invalidated by
  a direct grow call.
- `hashmap-iter-mutation`: the HashMap equivalent.
- `iterator-invalidation-mutation`: general iterator + mutation pattern.
