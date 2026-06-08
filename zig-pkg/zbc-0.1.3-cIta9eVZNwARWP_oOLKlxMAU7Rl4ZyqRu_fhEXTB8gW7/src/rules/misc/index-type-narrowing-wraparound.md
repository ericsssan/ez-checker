# index-type-narrowing-wraparound

A loop index or buffer-size variable is declared with a signed integer
type narrower than `usize` — `i8`, `i16`, or `i32` — and its initialiser
comes from a `.len` expression, or the variable is subsequently used as an
array subscript.  When the iterated collection has more items than the type
can represent, the index wraps around; the loop either never executes or
runs in reverse.

## Example

```zig
// BUG: i16 can represent at most 32 767; a path longer than 32 767
// bytes makes @intCast wrap and i starts negative — the while loop
// never executes.
var i: i16 = @intCast(decoded_pathname.len) - 1;
while (i >= 0) : (i -= 1) {
    if (decoded_pathname[@intCast(i)] == '/') break;
}

// FIX: use usize (or at minimum i64 for 64-bit systems):
var i: usize = decoded_pathname.len;
while (i > 0) {
    i -= 1;
    if (decoded_pathname[i] == '/') break;
}
```

The canonical instance of this bug is oven-sh/bun#31129, where a
`url_path` scanner used `i16` for a reverse-scan index; on any path
longer than 32 KB the index silently wrapped and the scan produced
a wrong result.

## When this might be a false positive

- **Intentionally small domain**: if the loop is genuinely bounded
  by a compile-time constant smaller than the type's maximum (e.g. an
  array of exactly 100 elements), the narrower type cannot wrap.  In
  that case the initialiser will not come from `.len` at runtime, so
  the heuristic typically won't fire; if it does, suppress with a
  `// zbc-disable-line` comment.

- **Bit-manipulation usage**: a variable typed `i16` that is only ever
  ANDed with a mask (`& 0xFF`) is not an index at all.  The rule
  fires only when the declaration comes from `.len` or the name appears
  inside `[...]`, so pure bit-manipulation patterns should not trigger.

To suppress on a specific line:

```zig
var i: i16 = @intCast(arr.len) - 1;  // zbc-disable-line:index-type-narrowing-wraparound
```
