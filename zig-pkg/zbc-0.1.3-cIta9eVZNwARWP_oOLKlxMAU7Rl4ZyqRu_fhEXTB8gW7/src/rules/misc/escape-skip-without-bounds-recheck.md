# escape-skip-without-bounds-recheck

**Severity:** error  
**Category:** bounds / OOB read  
**Tier:** 1 (token walk)

## What this checks

Inside a loop, an `if (buf[i] == ESCAPE_CHAR) { i += 1; }` escape-skip
is immediately followed by an unconditional `i += 1;` without a preceding
bounds guard.  If the escape character is the very last byte in the buffer,
the inner `+= 1` advances `i` to `buf.len`.  The subsequent unconditional
increment (or the next iteration's `buf[i]`) then reads one byte past the end.

## Example (fires)

```zig
fn highlight(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len and text[i] != '}') {
        if (text[i] == '\\') {  // ← BUG: no "i + 1 < text.len" guard
            i += 1;
        }
        i += 1;                 // ← OOB when '\\' was the last byte
    }
}
```

## Fix

Add a bounds guard before the array access in the if condition:

```zig
while (i < text.len and text[i] != '}') {
    if (i + 1 < text.len and text[i] == '\\') {  // ← bounds check added
        i += 1;
    }
    i += 1;
}
```

Or, break/continue after the inner increment so the outer `+= 1` is skipped:

```zig
if (text[i] == '\\') {
    i += 1;
    if (i >= text.len) break;
    i += 1;
    continue;
}
i += 1;
```

## Real-world instance

- oven-sh/bun#31435 — `fmt.zig` JS syntax highlighter: a trailing `\`
  inside an unterminated `${}` template interpolation advanced the scanner
  one byte past the end of the input, causing an OOB read / crash.
