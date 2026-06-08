# tagged-union-payload-early-exit

An assignment of the shape `<path> = .{ .<Tag> = <expr> };` where `<expr>`
contains a `try` (or an early-exit `catch` block) causes Zig's compiler to
write the union tag to the result location **before** evaluating the payload
expression.  If the payload expression propagates an error and exits early, the
LHS is left with the new tag but with the **payload bytes from the previous
variant** — a corrupt state that subsequent code (including `errdefer` cleanup
handlers) may misinterpret as a valid value.

## Why this matters

Tagged unions in Zig are represented as `{ tag, payload }`.  When the compiler
lowers `x = .{ .NewTag = expr }`, it must:

1. Write the new tag to `x.tag` (flips the active variant).
2. Evaluate `expr`.
3. Write the result to `x.payload`.

If `expr` contains `try` and the attempted operation returns an error, execution
transfers out of the enclosing function **between steps 1 and 3**.  The tag has
been updated but the payload bytes still hold whatever the previous variant
stored — an aliased, potentially dangling interpretation of the data.

Any subsequent read of `x` (for example an `errdefer x.deinit()` registered
before the assignment, or a caller that inspects `x` on the error path) will
mis-dispatch on the new tag and read the old variant's payload bytes as if they
belonged to the new type.

## Example

```zig
// BUG: tag `.err` is written to `resolve.value.tag` BEFORE the `try`
// evaluates.  If `logger.Msg.fromJS` returns `error.JSError` the handler
// returns early — `.err` is the active tag but the payload is whatever
// `.ok` held before.
resolve.value = .{
    .err = logger.Msg.fromJS(globalObject, value) catch |err| switch (err) {
        error.JSError => {
            return globalObject.throwValue(globalObject.pendingException());
        },
    },
};

// FIX: hoist the fallible expression before the literal assignment
const msg = logger.Msg.fromJS(globalObject, value) catch |err| switch (err) {
    error.JSError => {
        return globalObject.throwValue(globalObject.pendingException());
    },
};
resolve.value = .{ .err = msg };
```

## When this might be a false positive

- **Untagged / plain struct literals**: if the type being assigned is an
  ordinary struct (not a tagged union) the tag-flip hazard doesn't apply.
  The rule suppresses multi-field literals (`.{ .a = …, .b = … }`) as a
  heuristic, because real tagged-union variant assignments are always
  single-field.  If your struct genuinely has only one field and includes a
  `try`, the rule will fire even though there is no union tag involved.  In
  that case you can safely ignore the diagnostic or hoist the `try` anyway
  for clarity.

- **`const`/`var` declarations**: `const x = .{ .tag = try f() };` is not an
  assignment to an existing location — no prior variant exists — so the rule
  skips it.  Only assignments to pre-existing paths (`self.field = …`,
  `ptr.* = …`) are checked.
