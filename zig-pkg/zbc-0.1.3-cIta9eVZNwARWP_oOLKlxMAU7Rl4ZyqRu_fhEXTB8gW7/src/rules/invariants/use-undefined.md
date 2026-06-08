# use-undefined

Reading a value that was declared `undefined` and never assigned
a real value before the read.  In debug builds this is a panic;
in release builds it is whatever garbage happened to be in memory.

## Example

Incorrect:

    var x: T = undefined;
    process(x);                         // ← reads undefined memory

Fix — assign before use, or move the declaration to the point of
first assignment:

    var x: T = undefined;
    initialize(&x);
    process(x);

## When this might be a false positive

- **Method-call initialization.**  `var x: T = undefined;
  x.init(...);` is the canonical Zig initialization pattern.  zbc
  recognises method-call mutator names (`init*`, `set*`, `reset*`,
  `deinit`, `clear*`, `open`, `load*`, `close`) and treats them as
  writes, not reads.  If your initializer has a different name
  shape, rename it to fit the convention.
- **Field-by-field initialization.**  `var x: T = undefined; x.a =
  1; x.b = 2; return x;`.  Each field assign clears the parent's
  `.undef` state.

## Related

- (none — this rule is distinct from the resource-tracking rules.)
