# partial-union-write

A long-lived location (`x.* = ...` or `obj.field = ...`) is assigned
an anonymous tagged-union literal `.{ .tag = <expr> }` where `<expr>`
contains an early-exit — `try ...`, `catch return ...`, or
`catch |err| { ... return ...; ... }`.

Zig writes the union TAG to the result location *before* it evaluates
the payload expression.  If the payload's evaluation early-exits, the
LHS is left holding the **new tag with the old or garbage payload
bytes**.  A subsequent read (commonly via an `errdefer this.deinit()`
that dispatches on the union tag) follows a wild pointer or runs the
wrong destructor.

The fix is to hoist the fallible expression into a local first, so the
union literal is constructed only on the success path:

    const tmp = try fallible();
    lhs.* = .{ .tag = tmp };

## Example

Incorrect — `this.listener` is left with tag `.namedPipe` and a
garbage payload when `listen` errors; the surrounding
`errdefer this.deinit()` then dereferences it:

    errdefer this.deinit();
    this.listener = .{
        .namedPipe = WindowsNamedPipeListeningContext.listen(
            globalObject, pipe_name, 511, ssl, this,
        ) catch return globalObject.throwInvalidArguments(
            "Failed to listen at {s}", .{pipe_name},
        ),
    };

Fix — bind the result first, then assign:

    const named_pipe = WindowsNamedPipeListeningContext.listen(
        globalObject, pipe_name, 511, ssl, this,
    ) catch return globalObject.throwInvalidArguments(
        "Failed to listen at {s}", .{pipe_name},
    );
    this.listener = .{ .namedPipe = named_pipe };

## When this might be a false positive

- The catch arm cannot run before the assignment completes — e.g. it
  ends in `unreachable` placed only for an arm the compiler knows is
  dead.  zbc can't prove arm-level unreachability; rewrite the
  expression to hoist the local anyway, or split into a `switch`.
- The LHS is a function-local var that is *never* read after the
  early-exit path.  Currently this rule fires only on `x.*` and
  `obj.field` LHS shapes, which already excludes pure-local writes —
  but if you have an `errdefer use(local);` over a local, the same
  bug exists, and the rule will miss it (false negative, not false
  positive).

## Related

- `heap-use-after-free`: typical downstream symptom when the bad
  payload happens to be a dangling pointer.
- `use-undefined`: a different shape (the local was declared
  `undefined` and never assigned), but produces a similar read-of-
  garbage at runtime.
