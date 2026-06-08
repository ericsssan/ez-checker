# duplicate-errdefer

Two `errdefer` statements register the same cleanup call (e.g.
`errdefer X.deinit();`) against the same receiver `X` in one
function body.  On the error path Zig fires errdefers in reverse
declaration order — and here both registrations fire — so the
cleanup runs twice on the same resource.  The second call hits
its `deinit` assert, double-frees the underlying handle, or
corrupts shared state.

The fix is to remove the duplicate registration.  The typical
cause is copy-paste during refactoring: an `init` step is moved
or duplicated without removing the matching `errdefer`.

## Example

Incorrect — `errdefer command.io.deinit()` is registered twice;
on error, `IoUring.deinit` runs twice and trips
`assert(self.fd >= 0)`:

    command.io = try IO.init(128, 0);
    errdefer command.io.deinit();

    // …other init steps that aren't here originally…

    command.io = try IO.init(128, 0);        // ← copy-paste of the
    errdefer command.io.deinit();            //    same registration

Fix — drop the duplicate `IO.init` + `errdefer`:

    command.io = try IO.init(128, 0);
    errdefer command.io.deinit();

    // …other init steps…

## When this might be a false positive

- The two errdefers genuinely target different lifetimes — e.g.
  `errdefer X.deinit()` for an early-success state, then a later
  `errdefer X.deinit()` after a refactor where `X` was rebound to
  a fresh resource.  Rename the second resource (`var X2 =
  rebuild()`) to remove the ambiguity, or wrap the inner section
  in a labeled block that releases the first errdefer.

## Related

- `missing-errdefer-between-tries`: the inverse — a fn that's
  MISSING an errdefer between two `try`s.  Together the rules
  catch both under- and over-registration of cleanup.
- `dead-errdefer-in-result-fn`: errdefer that never fires at all
  because the enclosing fn returns `Result(T)`, not `!T`.
