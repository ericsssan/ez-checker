# else-literal-absorbs-addend

`if (COND) EXPR else 0 + ADDEND` — Zig's `if` expression has lower precedence than `+`, so this parses as `else (0 + ADDEND)`, silently dropping `ADDEND` from the result when `COND` is true.

## What the rule checks

The rule fires on the 3-token sequence `else <0-or-1> +` at the top level of a token walk. This pattern is the exact shape of the operator-precedence trap: the addend after `else 0` or `else 1` is absorbed into the else-branch instead of being added unconditionally.

The naturally-correct form `(if (cond) x else 0) + n` has `)` at the third position rather than `+`, so it does not trigger the rule.

## Why it matters

In Zig, `if` expressions are not statements — they produce a value — but their precedence is **lower** than arithmetic operators. So:

```zig
base + if (cond) 1 else 0 + extra
```

parses as:

```zig
base + (if (cond) 1 else (0 + extra))
```

When `cond` is true, the result is `base + 1` and `extra` is silently discarded. This is almost always a capacity-calculation bug.

## Real-world instances

- **oven-sh/bun#30466** (and 20+ duplicate PRs): `ensureTotalCapacity(defaults.len + 2 + if (allow_addons) 1 else 0 + conditions.len)` — when `allow_addons` was true (the default for `Bun.build`), `conditions.len` was dropped from the capacity request. Passing several custom conditions then caused `putAssumeCapacity` to write past the reserved slots, crashing the bundle thread.

## Fix

Parenthesize the `if` expression or use `@intFromBool`:

```zig
// Option 1: explicit parentheses
base + (if (cond) 1 else 0) + extra

// Option 2: @intFromBool
base + @intFromBool(cond) + extra
```
