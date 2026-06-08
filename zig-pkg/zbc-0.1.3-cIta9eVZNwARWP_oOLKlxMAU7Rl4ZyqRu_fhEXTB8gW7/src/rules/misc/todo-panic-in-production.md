# todo-panic-in-production

`@panic("TODO ...")` / `@panic("unimplemented")` /
`@panic("FIXME ...")` / similar markers left in code that may
run in release builds.  TODO-panics are a development scaffold:
harmless during prototyping but escalate to runtime crashes if
the path is reached in production.

## Shape

```zig
pub fn render(target: Target) ![]u8 {
    return switch (target) {
        .html => renderHtml(),
        .json => renderJson(),
        .yaml => @panic("TODO: yaml renderer"),  // ← user calls render(.yaml) → crash
    };
}
```

## Detection

Per-fn token walk:
1. Find `@panic(<string-literal>)` builtin calls.
2. Strip the literal's quotes.
3. Match TODO-marker patterns (case-insensitive prefix or
   contained "TODO" substring):
   - `TODO` / `FIXME` / `XXX` / `HACK` / `WIP`
   - `unimplemented` / `not implemented` / `not yet`
   - `stub`
4. Fire on the `@panic` call.

`unreachable` is intentionally NOT flagged — most uses are
proven-unreachable assertions after exhaustive switches.
Distinguishing intent would need flow analysis.  The rule
targets only the `@panic(<msg>)` form where the author wrote a
clear human signal.

## Fix patterns

For paths that genuinely aren't implemented yet but might be
hit, return an explicit error:

```zig
pub fn render(target: Target) ![]u8 {
    return switch (target) {
        .html => renderHtml(),
        .json => renderJson(),
        .yaml => error.NotYetImplemented,
    };
}
```

For paths that should be unreachable by construction, gate at
compile time:

```zig
pub fn render(comptime target: Target) ![]u8 {
    return switch (target) {
        .html => renderHtml(),
        .json => renderJson(),
        // yaml is comptime-rejected at the call site
    };
}
```

For genuinely impossible branches, `unreachable` is the right
primitive (compiler optimises it in release; safety-checked
builds turn it into a clearer panic).

## Real-world

Common in large Zig codebases as a development scaffold.  Bun
ships ~30 TODO panics on its main branch; tigerbeetle has none
(strict project conventions).  CI rarely covers every panic-
reachable branch — many escape into release builds.
