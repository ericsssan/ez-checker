# arraybuffer-slice-without-pin

A raw byte slice is taken from a JSC-managed buffer via `.slice()`,
`.utf8()`, `.latin1()`, `.utf16()`, etc., then a function is called
that may trigger GC (via JSC dispatch).  After the GC call, the
backing buffer may have been moved or freed — the slice is a dangling
pointer.

Real-world: oven-sh/bun#31339, multiple instances.

## Why this matters

JSC's garbage collector can move or free managed buffers during any
call that re-enters the JavaScript engine.  A raw slice taken via
`.slice()` or `.utf8()` is a direct pointer into that managed buffer.
If GC runs between the slice call and the last use of the slice, the
pointer may be invalid.

## Canonical bug

```zig
const bytes = buffer.slice();           // raw ptr into GC-managed buffer
doSomethingThatCallsJS(vm, ...);        // may trigger GC → buffer may move
use(bytes);                             // UAF
```

## Fix

Pin the buffer before taking the slice and unpin it after the slice
is no longer needed:

```zig
var pinned = buffer.pin(globalObject);
defer pinned.unpin();
const bytes = pinned.slice();
doSomethingThatCallsJS(vm, ...);        // buffer is pinned — safe
use(bytes);
```

## Detection

The rule scans each function body for:

1. A `const/var NAME = recv.method()` binding where `method` is a
   raw-view method: `slice`, `utf8`, `latin1`, `utf16`, `utf16le`,
   `bytes`, `toSlice`, `toOwnedSlice`, or `constSlice`.

2. After the binding, any call that may invoke GC:
   - A direct `recv.method(` call where `method` is a known JSC
     dispatch method (`call`, `evaluate`, `resolve`, `reject`, etc.).
   - A bare `identifier(` call where the callee is a same-file function
     whose body calls a GC-trigger method.

3. FP suppression: if a `.pin(` call appears on the same buffer
   receiver between the slice binding and the GC call, the fire is
   suppressed.
