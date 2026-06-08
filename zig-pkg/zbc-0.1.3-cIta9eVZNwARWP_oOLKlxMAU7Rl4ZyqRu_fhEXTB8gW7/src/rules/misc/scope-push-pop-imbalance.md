# scope-push-pop-imbalance

A parser or other stateful function calls a scope-push method
(`pushScope`, `enterScope`, `pushContext`, etc.) but does not protect
the matching pop with a `defer` statement.  When the function has
multiple exit paths (early `return`), the non-deferred pop is only
reached on the "happy" path — early returns leave the scope stack one
level too deep, causing underflows on subsequent calls.

## Example

```zig
// BUG: popScope only called on the success path.
// An early return before it leaves the scope stack unbalanced.
pub fn parseBlock(p: *Parser) !void {
    try p.pushScope(.block);  // BUG: no defer for the pop
    const token = try p.next();
    if (token == .eof) return error.UnexpectedEof;  // early return — no pop!
    try p.parseStatements();
    p.popScope();             // only reached on success
}

// FIX: wrap the pop in defer so it fires on every exit path.
pub fn parseBlock(p: *Parser) !void {
    try p.pushScope(.block);
    defer p.popScope();
    const token = try p.next();
    if (token == .eof) return error.UnexpectedEof;
    try p.parseStatements();
}
```

Real-world instances include oven-sh/bun#31239, #31340, and #31231, where
parser functions pushed a scope but returned early via `?Option` before
calling the matching pop — causing the scope stack to underflow on
subsequent parses.

## When this might be a false positive

- **Cleanup function**: if the function itself is the pop/cleanup
  (e.g. named `cleanupScope`, `exitParser`), it intentionally omits a
  paired pop.

- **Single exit path**: if the function has no early returns the non-deferred
  pop is safe.  The rule requires at least one `return` in the body before firing.

- **Conditional push**: if the push is inside an `if` block and returns
  are outside that block, a re-analysis of control flow would be needed.
  The Tier-1 token walk may flag this conservatively.

To suppress on a specific line, add a `// zbc-disable-line:scope-push-pop-imbalance` comment.
