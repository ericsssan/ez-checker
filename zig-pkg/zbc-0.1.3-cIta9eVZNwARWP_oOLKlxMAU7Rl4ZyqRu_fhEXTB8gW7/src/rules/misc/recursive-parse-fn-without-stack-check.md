# recursive-parse-fn-without-stack-check

**Severity:** error  
**Category:** stack overflow / denial of service  
**Tier:** 1 (token walk, per-fn body)

## What this checks

A parser, visitor, or scanner function (name contains "parse", "skip",
"visit", or "scan") calls itself recursively without a stack-depth guard
such as `is_safe_to_recurse()`.  Adversarially deep input — thousands of
nested type expressions, statement blocks, or AST nodes — exhausts the call
stack and hard-crashes the process.

## Example (fires)

```zig
const Parser = struct {
    pub fn skipType(p: *Parser) void {
        // processes nested type — no guard
        while (p.peek() == '[') {
            p.advance();
            p.skipType();   // ← recursive call, no stack check
        }
    }
};
```

## Fix

Add a stack-overflow guard at the top of the function and return an error
(or report a diagnostic) when the stack is too deep:

```zig
const Parser = struct {
    stack_check: bun_core.StackCheck,

    pub fn skipType(p: *Parser) !void {
        if (!p.stack_check.is_safe_to_recurse())
            return error.StackOverflow;
        while (p.peek() == '[') {
            p.advance();
            try p.skipType();
        }
    }
};
```

Alternatively, thread a `depth: u32` parameter and return an error when
it exceeds a known-safe maximum.

## Suppression

- Functions with a parameter named `depth`, `max_depth`, `nesting_depth`,
  or `level` are suppressed — they already carry an explicit depth counter.
- Functions whose body calls `is_safe_to_recurse`, `isSafeToRecurse`,
  `isStackOverflow`, `safeRecurse`, `checkStack`, `checkRecursion`, or
  `stackOverflow` are suppressed.

## Real-world instances

- oven-sh/bun#31361 — `skip_typescript_type` / `skip_type_script_binding`
  in the transpiler lacked `is_safe_to_recurse()` guards; deeply nested
  TypeScript tuple types (e.g. `[[[...0...]]]` with tens of thousands of
  levels) would crash the process with a stack overflow.
- oven-sh/bun#31333 — `visit_stmt` / `print_stmt` / `print_if` lacked
  guards; a cascade of deeply nested `{ }` blocks or `else if` chains
  reached only by those passes (not the parser) would overflow.
