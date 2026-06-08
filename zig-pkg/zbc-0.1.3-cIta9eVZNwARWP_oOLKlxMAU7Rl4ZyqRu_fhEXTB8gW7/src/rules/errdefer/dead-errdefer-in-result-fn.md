# dead-errdefer-in-result-fn

A function whose return type is a parameterized tagged-union — e.g.
`Result(T)`, `Maybe(T)`, `ParseResult(T)` — contains an `errdefer`
in its body.  Zig's `errdefer` only fires on a **Zig error return**
(`return error.OutOfMemory` / `try someCall()` propagating up).
`return .{ .err = e }` is a *normal* return through a tagged-union
variant, so the errdefer never runs.  Any cleanup the errdefer was
meant to perform is silently dropped, leaking whatever owned value
it was guarding.

The fix is to inline the cleanup at each error-shaped return site,
or convert the function to actually return an error union (`!T`
instead of `Result(T)`).

## Example

Incorrect — `light` is heap-owned by the parser, `errdefer
light.deinit();` looks like cleanup but the parser returns `Result`
via `return .{ .err = e }` which is a normal return; the errdefer
never fires:

    pub fn parseColor(input: *Parser) Result(UnresolvedColor) {
        const light = switch (parseRGB(input)) {
            .result => |v| v,
            .err => |e| return .{ .err = e },
        };
        errdefer light.deinit();   // dead — never fires
        if (input.expectComma().asErr()) |e| {
            return .{ .err = e };  // leaks `light`
        }
        // …
    }

Fix — inline the cleanup at each error-shaped return:

    pub fn parseColor(input: *Parser) Result(UnresolvedColor) {
        var light = switch (parseRGB(input)) {
            .result => |v| v,
            .err => |e| return .{ .err = e },
        };
        if (input.expectComma().asErr()) |e| {
            light.deinit();
            return .{ .err = e };
        }
        // …
    }

## When this might be a false positive

- The function does have a `try` path that genuinely propagates
  Zig errors (in addition to its `Result` returns).  Currently
  rare in Result-returning APIs — they conventionally don't mix
  the two error-return styles.  If you intentionally mix, convert
  the fn to `!T` to make both styles consistent.
- The errdefer's body is also paired with explicit cleanup at
  each error-return site (defensive double-cleanup).  Rare; the
  errdefer line is dead code regardless and removing it doesn't
  change behavior.

## Related

- `missing-errdefer-between-tries`: the inverse — a function with
  proper `!T` return where `errdefer` is genuinely needed but
  missing.  This rule catches the opposite shape: `errdefer`
  present in a fn where it can't fire.
