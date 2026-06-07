# Oracle test suite

ez-checker's **true test suite** is its conformance against the TypeScript
compiler's own test corpus — the same corpus TypeScript uses to test itself.
`tsc` is the ground-truth oracle. No hand-written assumptions, no cherry-picking:
every `.types` baseline records the type `tsc` inferred for every expression, and
the suite checks ez-checker against all of them at once.

## The gate — `zig build test-oracle`

The headline test (`oracle_test.zig` → `oracle_corpus.zig`) sweeps **every**
single-section `.types` baseline in the vendored submodule
(`typescript/tests/baselines/reference/`, ~14k files), compares ez-checker's
inferred type for every expression against `tsc`, and **fails the build on any
regression** against the committed baseline (`oracle/baseline.lock`):

- `prim_match` drops below `prim_match_min` — fewer correct answers
- `prim_wrong` rises above `prim_wrong_max` — more wrong concrete answers
- `sections_eval` drops below `sections_eval_min` — sections silently stopped evaluating
- any section raises a pipeline error — `sections_errored` must be 0

It's a **one-way ratchet**. `oracle/baseline.lock` is **tool-generated, never
hand-edited** — after a verified improvement, run:

```
zig build save-baseline
```

which re-runs the sweep and overwrites the lock with the current numbers (also
`oracle --save-baseline`). The sweep is deterministic (same counts every run) and
takes a few seconds.

The whole oracle is one file, `oracle.zig` at the repo root: its `test` block is
the gate (`test-oracle`) and its `main()` is the executable (`run-oracle` /
`save-baseline`).

## Ad-hoc runs — `zig build run-oracle`

The same sweep as a standalone executable that prints the full report instead of
asserting — for scoped runs, debugging, or inspecting mismatches.

```
zig build run-oracle
```

### How it works

A `.types` baseline interleaves each source line with `>expr : type` entries —
one for every expression `tsc` typed:

```
=== file.ts ===
var x11 = foo([{a:0}]);
>x11 : string
>    : ^^^^^^
>foo([{a:0}]) : string
>             : ^^^^^^
...
```

Every `.types` file is split into its `=== name ===` sections (single- and
multi-section baselines are handled uniformly), and each code section is
evaluated in its own language (`.ts`/`.tsx`/`.d.ts`/`.mts`/`.cts`/`.js`/`.jsx`).
Per section, the sweep:

1. **Reconstructs the effective source** from the non-`>` lines. This is
   *exactly* the text the baseline's `expr` fragments were sliced from, so
   parsing it makes AST node line-numbers and node source-text line up with the
   baseline with **zero realignment** — no need to read the original `.ts` or
   guess at stripped `// @directives`.
2. **Extracts each `(expr, type)`** using the decoration line's first `^`
   column as the expr/type boundary (the only reliable split, since both exprs
   *and* types can contain `" : "` — ternaries, object-type literals, casts).
3. **Runs ez-checker** and builds a `(line, node-source-text) → type` map over
   all AST nodes, using exact full-subtree spans (`node_end_toks` for the end,
   leftmost-leaf recursion for the start).
4. **Compares** each baseline expression's `tsc` type against ez-checker's,
   after normalizing simple unions (ez-checker sorts union members; `tsc` does
   not).

### Reading the output — nothing is hidden

```
 sections            : total | evaluated | non-code skip (.json/none) | too-large skip | pipeline errors
 baseline expressions: every >expr:type entry
   comparable        : …had a single ez node  (the rest had no comparable node; N of those ambiguous)
 all-types match     : correct / comparable

 primitive subset    : every primitive/literal-typed expression — fully bucketed:
   ├─ correct        : ez == tsc                         ← the conformance number
   ├─ wrong concrete : ez = a different concrete type    ← divergence / bug
   ├─ coverage gap   : ez = error/unknown/any            ← unmodeled (admits it doesn't know)
   └─ no ez node     : no comparable node                ← anchoring / coverage gap
```

The **primitive subset** is the meaningful metric — the slice of the language
ez-checker is built to model — and its four buckets *sum to the whole subset*, so
the denominator can't be quietly shrunk to flatter the rate. Conformance =
`correct / primitive-subset`. The honest failure modes are split out: **wrong
concrete** is where ez confidently disagrees with `tsc` (real bugs); **coverage
gap** and **no ez node** are where ez doesn't (yet) model or anchor a
construct. Structural gaps — non-code sections, over-large sources, ambiguous
anchors — are all counted and printed rather than dropped silently.

After the summary the report is **verbose by default**: a conformance-by-language
table (`ts`/`d.ts`/`tsx`/`js`/`jsx`), then three breakdowns — *wrong concrete*,
*coverage gap*, and *no ez node* — each grouped by `tsc type category → ez type
category`, sorted by frequency, with a concrete `file: expr  want … got …`
example per row. This shows *where* ez diverges systematically (e.g. "ez returns
`string` for `typeof x`", "ez can't model `union` returns"), not just how often.

### Env knobs

| Variable          | Effect                                             |
|-------------------|----------------------------------------------------|
| `ORACLE_FILTER=s` | Only files whose name contains `s`                 |
| `ORACLE_SKIP=a,b` | Skip files whose name contains any listed substring |
| `ORACLE_LIMIT=N`  | Stop after `N` files                               |
| `ORACLE_PROGRESS=1`| Print each file as it's processed (locating hangs) |
| `ORACLE_DIR=path` | Use a different baseline directory (for debugging)  |

The sweep is self-contained from the `.types` files — it never reads the
original `.ts` sources.
