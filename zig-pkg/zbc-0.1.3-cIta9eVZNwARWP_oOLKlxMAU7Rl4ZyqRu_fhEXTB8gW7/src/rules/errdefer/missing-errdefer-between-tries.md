# missing-errdefer-between-tries

A heap-owning local is bound via `const X = try <Type>.<method>(...);`,
and a subsequent `try` in the same function appears with NO
`errdefer X.deinit();` registered between the binding and the
second `try`.  If the second `try`'s expression throws, Zig
propagates the error upward without running any cleanup for `X` —
the allocation leaks every time the second call fails.

The fix is to register the errdefer immediately after the binding:

    const old_path = try PathLike.fromJS(ctx, args) orelse …;
    errdefer old_path.deinit();
    const new_path = try PathLike.fromJS(ctx, args) orelse …;

## Example

Incorrect — `old_path` leaks if the second `PathLike.fromJS` throws:

    const old_path = try PathLike.fromJS(ctx, arguments) orelse {
        return ctx.throwInvalidArgumentTypeValue(...);
    };
    // ← missing: errdefer old_path.deinit();
    const new_path = try PathLike.fromJS(ctx, arguments) orelse {
        return ctx.throwInvalidArgumentTypeValue(...);
    };
    return .{ .old_path = old_path, .new_path = new_path };

Fix — register the errdefer immediately so the next failure cleans
up:

    const old_path = try PathLike.fromJS(ctx, arguments) orelse {
        return ctx.throwInvalidArgumentTypeValue(...);
    };
    errdefer old_path.deinit();

    const new_path = try PathLike.fromJS(ctx, arguments) orelse {
        return ctx.throwInvalidArgumentTypeValue(...);
    };
    errdefer new_path.deinit();

    return .{ .old_path = old_path, .new_path = new_path };

## When this might be a false positive

- The type's `deinit` is a no-op (the value owns no heap), and the
  registered errdefer would just be noise.  Either remove the
  no-op deinit (so the rule stops considering the type heap-shape)
  or accept the rule's suggestion as a clarity improvement.
- The binding's call returns OWNED-BY-CALLEE values that the
  callee manages on error.  Rare — fromJS / parse / decode style
  fns conventionally hand ownership to the caller on success.

## Related

- `heap-leak`: the type-level version where a type's destructor
  itself fails to free `self`.
- `asymmetric-field-free`: a sibling-fields generalization of the
  destructor-completeness check.
