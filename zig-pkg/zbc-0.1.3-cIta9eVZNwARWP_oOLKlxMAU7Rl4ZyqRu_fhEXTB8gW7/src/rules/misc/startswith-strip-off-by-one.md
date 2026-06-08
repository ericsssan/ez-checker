# startswith-strip-off-by-one

`startsWith(SLICE, "LITERAL")` followed by `SLICE[literal.len-1..]` — an off-by-one when stripping the prefix. The slice offset is one less than the prefix length, leaving the last character of the prefix behind.

## What the rule checks

The rule fires when `startsWith(SLICE, "LITERAL")` (or the `std.mem.startsWith(u8, SLICE, "LITERAL")` form) is immediately followed (within 40 tokens) by `SLICE[N..]` where `N == "LITERAL".len - 1` — exactly one short of the correct offset. It does not fire when:
- The offset is correct: `SLICE["LITERAL".len..]`
- The offset differs by more than 1 (a different, unrelated slice)
- The string literal contains backslash escape sequences (length cannot be computed from the token)
- The slice uses a different variable than the startsWith check

## Why it matters

The pattern arises from copy-pasting a prefix-strip and updating the string literal without recalculating the offset. If `"file://"` has 7 characters and you strip with `[6..]`, the resulting slice starts with `/` instead of the path — silently producing malformed data passed to filesystem operations.

## Real-world instance

- **oven-sh/bun#27970** (`node_fs_watcher.zig`, `node_fs_stat_watcher.zig`): Both files checked `startsWith(slice, "file://")` but stripped with `slice[6..]`. Since `"file://"` is 7 characters, the resulting path always started with `/` — paths were technically still valid on Unix but structurally wrong. Fix: changed to `slice["file://".len..]` (= `slice[7..]`).

## Fix

```zig
// Instead of (off by one — retains last char of prefix):
if (strings.startsWith(path, "file://")) {
    return path[6..];  // "file://" is 7 chars
}

// Use the literal's .len to stay in sync:
if (strings.startsWith(path, "file://")) {
    return path["file://".len..];  // 7
}
```
