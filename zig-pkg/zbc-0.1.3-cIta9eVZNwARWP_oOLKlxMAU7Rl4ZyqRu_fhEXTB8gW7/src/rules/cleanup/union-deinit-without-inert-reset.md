# union-deinit-without-inert-reset

A `switch (<recv>.<field>)` arm calls a payload-cleanup method
(`v.deinit()` / `v.<sub>.deinit()` / `.free()` / `.release()` /
`.deref()` / `.destroy()` / `.close()`) on the captured payload but
doesn't retag `<recv>.<field>` to an inert variant.  The fn is
named `reset` / `clear` / `end` (idempotent by convention) — so
the next call sees the SAME active tag, fires the SAME arm, and
deinits the already-freed payload a second time.

## Why this matters

Idempotent state-machine reset methods are designed to be called
multiple times across the owner's lifetime: the parser resets
between commands, the renderer clears between frames, the watcher
ends each operation cleanly.  When such a method tears down a
union payload but forgets the retag, the union's tag still says
"there's a payload here" and the next call re-deinits.

Most modern `deinit` implementations assert on double-deinit
(`assert(self.fd >= 0)` / `assert(!self.freed)`) so this fails
loudly in debug but silently corrupts in release builds with
disabled asserts.

3 PRs in ghostty-org/ghostty's `src/terminal/osc.zig` alone
touched this same shape (#2257, #8307, #11955 partial) — the
pattern is invisible at the first call and only surfaces when the
parser is reused for a second sequence.

## Canonical bug (ghostty-org/ghostty#2257)

```zig
pub fn end(self: *Parser) void {
    switch (self.command) {
        .kitty_color_protocol => |*v| {
            v.list.deinit();
            // BUG: missing `self.command = .{ .hyperlink_end = {} };`
        },
        else => {},
    }
}
```

The `kitty_color_protocol` payload's list is freed.  But
`self.command`'s tag is still `.kitty_color_protocol`, so the next
`end()` call's switch arms re-fire and the freed list is
re-deinit'd.

## Fix

Retag the union to an inert variant after the cleanup:

```zig
pub fn end(self: *Parser) void {
    switch (self.command) {
        .kitty_color_protocol => |*v| {
            v.list.deinit();
            self.command = .{ .hyperlink_end = {} };  // inert reset
        },
        else => {},
    }
}
```

Or use `undefined` if the fn's contract is that the caller will
re-initialize before the next observation:

```zig
self.command = undefined;
```

## Why the detector is precise

- Limited to fn names matching the reset/clear/end family
  (`reset*`, `clear*`, `end`, `endCommand`, `endOperation`,
  `finish`, `end_*`) — these are the only fns where the bug
  surfaces because they're called multiple times.  `deinit` /
  `destroy` are single-shot, so missing retag doesn't matter
  there.
- Switch operand must be `<recv>.<field>` (single-identifier
  receiver and field) — the canonical state-machine shape.
- Arms without a capture (`.Tag => doStuff()`) are skipped — the
  rule requires a `|*v|` or `|v|` capture to know what to scan
  for as cleanup.
- Cleanup-call recognition walks the dotted chain from the
  capture (`v.list.deinit()`, `v.inner.cache.free()`) — supports
  multi-hop payload field access.
- Retag detection accepts both targeted assignment
  (`<recv>.<field> = ...`) and whole-struct reset
  (`<recv>.* = ...`).
- Both block bodies (`.<Tag> => |*v| { ... }`) and inline arms
  (`.<Tag> => |*v| v.list.deinit()`) are supported.
