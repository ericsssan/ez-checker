# borrowed-slice-into-out-param

`defer <X>.deinit()` (or `defer <alloc>.free(<X>)`) registers
cleanup for a local buffer / arena.  A later write
`<out>.* = ...<X>...` (or `<out>.<field> = ...<X>...`) where
`<out>` is a pointer-typed fn parameter pushes a view of `<X>`
into a caller-visible out-param.  When the defer fires on
function return, the out-param holds a dangling slice.

## Canonical bug (oven-sh/bun#30151)

```zig
pub fn parsePathOrSpecifier(query_string: *ZigString, ...) !void {
    var specifier_utf8 = bun_string.toUTF8(allocator);
    defer specifier_utf8.deinit();
    // ... parse result.query_string from specifier_utf8 ...
    query_string.* = ZigString.init(result.query_string);
    // ← result.query_string is a slice into specifier_utf8's bytes;
    //   defer fires on return → query_string dangles.
}
```

## Fix

Clone with the caller's allocator before assigning:

```zig
query_string.* = ZigString.init(try alloc.dupe(u8, result.query_string));
```

## Why the detector is precise

- The out-param must be a **pointer-typed parameter** (`*T`,
  `?*T`).  Value-typed parameters can't be modified by the caller
  anyway.
- The defer must be one of:
  - `defer <X>.deinit()` / `defer <X>.deinit(...)`
  - `defer <X>.close()`
  - `defer <alloc>.free(<X>)` (where `<X>` is the freed thing)
- The write must be at the top-level statement form:
  - `<out>.* = <RHS>` (deref-write through pointer)
  - `<out>.<field> = <RHS>` (field assignment through pointer)
- The RHS must mention a deferred name as an identifier
  somewhere — not necessarily as a direct argument.

## Limitations (deliberate)

- Doesn't distinguish cloning vs borrowing constructors in the
  RHS — `<out>.* = MyType.init(X)` fires whether `init` clones
  or just stores a reference.  Most `init(X)`-style calls in
  practice are non-cloning, so this is OK; cloning constructors
  produce no FP because the rule fires on the assignment but the
  semantic is benign.  Reviewer must verify.
- Doesn't track multi-hop aliasing — `const tmp = X; out.* = tmp;`
  wouldn't fire (only `X` is in deferred set, not `tmp`).
- Same-fn scope only; cross-fn defer / cleanup is out of scope.
