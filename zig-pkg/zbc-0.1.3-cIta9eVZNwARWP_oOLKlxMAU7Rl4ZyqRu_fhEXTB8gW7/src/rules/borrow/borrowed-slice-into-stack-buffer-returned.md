# borrowed-slice-into-stack-buffer-returned

A stack-local `var <buf>: [N]<T> = undefined;` is passed to an
aliasing parser (`SemanticVersion.parse`, etc.).  The parser
populates fields of the returned struct with slices INTO `<buf>`
(`.pre`, `.build`, etc.).  The returned struct is then `return`-ed
from the fn — but `<buf>` dies at fn return, leaving the caller
with a struct whose sub-slice fields dangle.

## Canonical bug (ziglang/zig#25713)

```zig
pub fn detectOsVersion() !SemanticVersion {
    var buf: [64]u8 = undefined;
    _ = try std.posix.sysctl(&mib, &buf, ...);
    const ver = SemanticVersion.parse(&buf);  // ver.pre/build alias buf
    return ver;
}
```

`SemanticVersion.parse(text)` does
`ver.pre = text[a..b]; ver.build = text[c..];` — both slices into
the input.  When `text` is a stack-local, those slices die at
function return.

## Fix

Strip the aliased sub-slices before returning, or clone them:

```zig
var stripped = ver;
stripped.pre = null;
stripped.build = null;
return stripped;
```

## Why the detector is precise

- The buffer must be a stack array declaration:
  `var <buf>: [<N>]<T> = undefined;`.  Heap allocations,
  parameters, struct fields don't match.
- The parsing call must be of the form `<T>.parse(<args>)` where
  `<args>` mentions one of the stack buffers.  Other-named
  parsing methods (`decode`, `unpack`) aren't matched —
  `parse` is the conventional name for the
  text-in / structured-out shape that aliases.
- The parse result must be `return`-ed for the bug to actually
  surface; locally-used parse results don't fire.

## Limitations

- Only catches `<T>.parse(...)` calls — other aliasing parser
  names are out of scope.
- Doesn't track flow through intermediate locals (`const tmp =
  ver; return tmp;` — would fire because `ver` is mentioned in
  the return).
