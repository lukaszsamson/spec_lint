# Source-clause mapping experiment (Milestone 4)

A diagnostic experiment, separate from production gating: can each clause
of the signature the compiler stores in the `ExCk` chunk be mapped back to
the source clauses it came from? This file is both the experiment's guide
and its report. The adopted part (the structural classes) is implemented in
`lib/spec_lint/clause_mapping.ex`; nothing in this directory is part of the
product.

Date 2026-09-29. Every measurement below is on compiler `c24c235` (the
replay copies its orchestration); the adopted classes are also argued from
the source of `648b2a9` and 1.20.4 and tested under both compiler lines.

| File | Purpose |
| --- | --- |
| `recompute.exs` | The experiment: mode A (structural classes, then recomputed head types and a constraint search over the pipeline's invariants in four typed variants) and mode B (an instrumented replay of `Module.Types.infer/7`, the oracle) |
| `fixtures.ex` | Fixture modules with hand-written expected mappings (`ClauseMappingFixtures.Expected`), including the review counterexamples (`Adv3`, `Adv4`, `Adv6`, `Adv7`) |
| `subpatterns_leak.ex` | Minimal reproducer of E1 (the checker's `subpatterns` leak between definitions) |
| `run.sh` | Runs the fixtures and the fifteen corpora |
| `table.sh` | Prints the per-corpus tables below from the summaries |
| `results/` | The run this report quotes: `*.summary.json`, `fixtures.txt`, `fixtures.rows.json`, `tables.md` (every variant) |

## Question and decision

SpecLint reports an SL001 clause conflict by the index of the stored
clause, and blocks it function-wide when the compiler's pattern and guard
check reports anything in the function, because stored clauses could not
be mapped back to source clauses. Milestone 4 asks which mappings compiler
invariants justify; agreement on the corpora alone does not prove
exactness.

**Decision.** Adopt the two structural classes, which follow from the
pipeline's invariants alone and need no type: a function with one source
clause (`:single`, including a default-argument wrapper), and a function
with as many stored as source clauses (`:identity`). They are used only to
name the source clause and its line in a clause conflict's details and
data. Everything else stays ambiguous, and `clause_reachable` blocking
stays function-wide for every function. No typed mapping is adopted:
recomputing head types is not exact (E1-E3), and the review found wrong
exact claims (R1-R2), one of them with no compiler warning.

On the fifteen corpora the structural classes cover 20,051 of the 21,439
functions with an inferred signature (93.5%) and 22,826 of their 27,742
stored clauses (82.3%); the replay oracle checked 19,825 of those
functions and agrees with every one. All nine clause conflicts of the
corpora (Absinthe's seven on `Absinthe.Blueprint.Input.parse/1`,
`Ash.Page.page_opts/1`, `Oban.Registry.via/3`) are in identity functions,
so each now names its source clause and line.

## Pipeline

For a `def`, `Module.Types.infer/7` (`lib/elixir/lib/module/types.ex` on
`c24c235`; `648b2a9` has the same file) stores
`group_clauses_by_return(inferred)` under `sig`, and
`elixir_erl:checker_chunk/4` writes it unchanged. `inferred` comes from
`local_handler/7` (lines 326-338; 1.20.4: 330-342):

1. a single clause whose body is `{:super, _, args}` (the generated clause
   of a function with default arguments) goes to `default_local_handler/9`
   (340-394), which applies the arrows of the full definition: one source
   clause, one or more stored clauses;
2. anything else goes to `infer_local_handler/7` (396-441; 1.20.4:
   400-455), which infers exactly one `{args, return, precise?}` per
   source clause, in source order (an internal error aborts compilation,
   so there is no partial result);
3. `group_clauses/1` (443-493, 1.21 only) drops precise clauses whose
   return is empty when some return is not (1.20.4 drops nothing and
   stores a raising clause as `-> none()`), then `add_inferred/5`
   (552-559; 1.20.4: 511-518) merges a clause into the first earlier one
   with term-equal arguments;
4. `group_clauses_by_return/1` (571-611; 1.20.4: 530-570) merges a clause
   into the first earlier one with the same return whose arguments differ
   in one position.

## Invariants

- **I1 (partition).** Each source clause ends in at most one stored clause
  (steps 2-4 map, never split), and each stored clause has at least one
  source clause.
- **I2 (order).** Both merges keep the merged clause at the position of its
  first member and append a new clause at the end, so stored clause `k`'s
  smallest source clause is smaller than stored clause `k + 1`'s.
- **I3 (drops).** A clause is dropped only if it is precise and some stored
  return is non-empty (1.21); 1.20.4 drops nothing.

From I1 and I2 alone:

- one source clause: every stored clause comes from it (`:single`);
- `n > 1` source clauses and `n` stored clauses: only
  `infer_local_handler/7` handles more than one source clause, and a
  partial map from `n` clauses onto `n` clauses that respects I1 is a
  bijection, which I2 makes the identity (`:identity`);
- more stored than source clauses contradicts I1 and is reported as
  ambiguous (`:more_stored_than_source`), never trusted. It does not occur.

The solver of `recompute.exs` also uses I4 (a kept precise clause has a
non-empty return when anything is dropped, from `group_clauses/1`), I5
(coverage: each stored argument type is inside the union of its members'
head types) and the assumption A1 (a body never empties a non-empty head
argument type). I5 and A1 need the members' head types, which is where the
typed variants fail.

## Method

`recompute.exs` maps every function of a module two ways.

- **Mode A** decides the structural classes from the clause counts and the
  `{:super, ...}` shape. For the rest it recomputes each source clause's
  head type with the checker's own `Pattern.of_head/8` in `:infer` mode and
  searches every assignment source clause -> stored clause | dropped that
  satisfies I1-I5 (and A1 in the `*_a1` variants). A stored clause is exact
  when every solution gives it the same members. `strict_*` take the fresh
  heads (`lo`) as the compiler's; `robust_*` use them only as bounds: `lo`,
  and `hi`, the same head with no previous clauses (and the open struct
  type for a protocol implementation's first argument).
- **Mode B** is an instrumented copy of `infer/7` that re-infers the whole
  module and records the compiler's own source -> inferred mapping, then
  `group_clauses_by_return` with index tracking. It is the oracle, used
  only where the replayed signature equals the stored one (term or
  semantic equality): 21,202 of 21,439 functions (98.9%).

## Experiments: recomputed heads are not the compiler's

- **E1: the `subpatterns` leak.** `fresh_context/1` (types.ex 708-710)
  resets `vars`, `failed` and `reverse_arrows` between clauses, not
  `subpatterns`. A `{:list, version}` entry left by one definition's list
  pattern makes a later guard on a variable of the same version imprecise
  (pattern.ex 990-996, 1226-1229), so the compiler subtracts fewer
  previous clauses than a fresh run. `subpatterns_leak.ex`: `LeakWith.b/1`
  is stored as `list -> integer() ; term() -> dynamic()` and
  `LeakWithout.b/1` as `list -> integer() ; not list -> dynamic(not list)`
  on `c24c235` and `648b2a9`. Sound (a wider domain), but a clause's head
  depends on unrelated definitions. On the corpora the fresh heads differ
  from the compiler's in 119 of the 3,237 functions where both were
  recorded.
- **E2: protocol implementations.** `Of.impl/2` (of.ex 289-301) gives the
  closed struct type for an implementation's first argument only when the
  struct module was loaded at compile time, so `lo` can differ from the
  compiler's head.
- **E3: subtraction widens a gradual upper bound.** Subtracting previous
  clauses from a gradual type can leave a head outside the no-previous
  `hi`: `Phoenix.HTML.Safe.Phoenix.LiveView.Rendered.to_iodata/1` (clauses
  at lines 133 and 137). Both clauses are errored in the fresh chain; with
  the R1 fix below their `hi` is unbounded, and every head recorded on the
  corpora is now between `lo` and `hi`.

## Review counterexamples (fixtures `Adv3`, `Adv4`, `Adv6`, `Adv7`)

- **R1: the redundant path.** A redundant clause (`of_head/8`, pattern.ex
  212-219 on `c24c235`) keeps the head left after subtracting the previous
  clauses, without its guard's refinement, so `hi` is not an upper bound.
  `Adv3.redundant/1` (warns) and `Adv4.gen_red/1` (the redundant clause is
  quoted with `generated: true`: no warning) are stored as `(atom() or
  integer()) -> ... ; (not atom() and not integer()) -> ...`, members
  `[[0], [1, 2]]`. Before the fix `robust_a1` claimed both stored clauses
  exact, and both were wrong. Fix: a clause the fresh chain types as
  errored gets an unbounded `hi` (`term()` per position); both functions
  are now ambiguous and bracket the truth.
- **R2: the leak with a generated repeated guard.** `Adv6.b/1` follows
  `a([x | _])`; its generated clause 1 repeats clause 0's `is_list/1` guard
  (no warning). The compiler's head for clause 1 is `list()` (E1), the fresh
  one is `not list()`, so `strict_a1` claims stored clause 0 exact as `[0]`
  where the truth is `[0, 1]`, and its bracket for stored clause 1 is
  unsound. Not fixed: every summary marks the typed variants'
  `exact_claims` as `unverified`.
- **R3: an identity lost by the solve.** `Adv7.ident/1` has three source
  and three stored clauses (clause 1 is redundant); the typed solve found
  no solution although I1 and I2 force the identity. Fix: the structural
  classes are decided before, and independently of, any typed solve, and
  "non-trivial" is computed from the clause counts only.

## Fixture results

`results/fixtures.txt` (wrong = wrong exact claims plus unsound brackets):

| Mapping | Wrong over the 27 fixture functions |
| --- | ---: |
| structural classes (adopted) | 0 |
| `robust_a1` | 0 (2 before the R1 fix) |
| `robust_inv` | 0 |
| `strict_a1` | 2 (`Adv6.b/1`, R2) |
| `strict_inv` | 0 |

The replay reproduces every fixture signature and agrees with every hand
expectation. One expectation was corrected after the first run, with the
reason recorded next to it in `fixtures.ex`: `guarded_imprecise/1` was
expected as `[[0, 2], [1]]`, which forgot that its clauses 0 and 1 have
term-equal domains (`integer()`: clause 0 is imprecise, so it is not
subtracted from clause 1) and merge in `add_inferred/5` before
`group_clauses_by_return/1` sees them; the merged return `:big or :small`
then differs from clause 2's `:big`, giving `[[0, 1], [2]]`.

The product's fixtures (`test/support/clause_mapping_fixtures.ex`,
`test/spec_lint/clause_mapping_test.exs`) pin the structural classes per
adapter: a raising clause and the generated redundant clause of
`gen_red/1` make those functions ambiguous on 1.21 and identities on
1.20.4, and for each identity the stored return of clause `k` contains the
atom that source clause `k` returns.

## Corpus results

`results/tables.md` has every table. Structural classes:

| Corpus | Functions | Structural functions | Stored clauses | Structural stored clauses | Replay reproduced | Structural replay-checked: agree / wrong | Heads: fresh = compiler / differs |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| stdlib | 3867 | 3582 (92.6%) | 4664 | 4061 (87.1%) | 3799 (98.2%) | 3524 / 0 | 574 / 49 |
| jason | 90 | 84 (93.3%) | 115 | 105 (91.3%) | 87 (96.7%) | 81 / 0 | 23 / 1 |
| decimal | 64 | 50 (78.1%) | 157 | 90 (57.3%) | 61 (95.3%) | 47 / 0 | 30 / 2 |
| nimble_options | 18 | 15 (83.3%) | 31 | 18 (58.1%) | 18 (100%) | 15 / 0 | 6 / 0 |
| mime | 6 | 6 (100%) | 6 | 6 (100%) | 6 (100%) | 6 / 0 | 0 / 0 |
| plug | 334 | 318 (95.2%) | 404 | 384 (95%) | 334 (100%) | 318 / 0 | 52 / 18 |
| ecto | 688 | 590 (85.8%) | 1005 | 767 (76.3%) | 685 (99.6%) | 587 / 0 | 176 / 11 |
| req | 268 | 257 (95.9%) | 297 | 284 (95.6%) | 262 (97.8%) | 251 / 0 | 26 / 1 |
| broadway | 122 | 119 (97.5%) | 147 | 143 (97.3%) | 122 (100%) | 119 / 0 | 15 / 0 |
| oban | 1184 | 1153 (97.4%) | 1316 | 1229 (93.4%) | 1176 (99.3%) | 1145 / 0 | 84 / 0 |
| phoenix_live_view | 1350 | 1184 (87.7%) | 1550 | 1283 (82.8%) | 1341 (99.3%) | 1175 / 0 | 239 / 3 |
| ash | 8926 | 8498 (95.2%) | 11561 | 9834 (85.1%) | 8853 (99.2%) | 8426 / 0 | 1249 / 12 |
| nx | 1385 | 1296 (93.6%) | 1556 | 1398 (89.8%) | 1371 (99%) | 1282 / 0 | 143 / 18 |
| absinthe | 2637 | 2417 (91.7%) | 4334 | 2654 (61.2%) | 2591 (98.3%) | 2371 / 0 | 405 / 1 |
| tesla | 500 | 482 (96.4%) | 599 | 570 (95.2%) | 496 (99.2%) | 478 / 0 | 96 / 3 |

The typed variants resolve many of the 1,388 non-structural functions
(`robust_a1`: 742 exact, 646 ambiguous; `strict_a1`: 1,009 exact, 358
ambiguous, 21 without a solution or unsupported) with no
disagreement with the replay on the corpora (`exact_wrong` 0 for every
variant; the `strict_*` variants find no solution for 20 and 19
replay-checked functions). That is agreement, not proof: the same variants are wrong on
warning-free fixtures (R2) and, before the R1 fix, were wrong on two more.
The corpus zero holds only because no replayed corpus function has those
shapes.

## What the product does with it

- `SpecLint.ClauseMapping.map/3` returns `{:exact, :single | :identity,
  per_stored}` or `{:ambiguous, reason}` from the debug info clauses and
  the stored clause count; `SpecLint.Analysis` attaches it to every
  function with an inferred signature.
- A clause conflict's details gain `source clause: #k, line L` (or "not
  determined ..."), its data `source_clause` (`index`, `line`, and `file`
  when the clause comes from another file) and `clause_mapping`.
  `--explain` annotates each inferred clause. The issue line (the
  function's first line), prerequisites, gates and fingerprints are
  unchanged.
- Blocking stays function-wide even for mapped functions: the checker's
  diagnostics carry lines, and attributing a line to a clause is not an
  invariant (generated clauses, several clauses on one line, guards on
  continuation lines). No clause conflict on the corpora is blocked by a
  diagnostic, so per-clause blocking would have changed no gate there.
- Mapping establishes neither reachability nor normal return.

## Requirements

- Elixir `c24c235` (the qualified fork revision) on `PATH`, with OTP 28.
  `recompute.exs` checks it with `SpecLint.Compiler.preflight/0`, which
  also verifies the build's identity, and exits 2 under any other
  compiler: the replay copies that revision's `Module.Types`
  orchestration, and on another one it would give meaningless results.
- A build of SpecLint (`TOOL_EBIN`); only `SpecLint.Beam` and the compiler
  adapter are used. Copy the ebin elsewhere if another process is
  compiling the checkout.
- For the corpora, the `c24c235` corpus builds of `bench/corpus`
  (`SPEC_LINT_OSS`: jason, decimal, nimble_options, mime, plug, ecto;
  `SPEC_LINT_EXPANSION`: req, broadway, oban, phoenix_live_view, ash, nx,
  absinthe, tesla; `bench/corpus/README.md`), and `ELIXIR_DIR`, the
  compiler's checkout, whose `lib/*/ebin` are the standard library corpus
  (default `$HOME/elixir`). The BEAM files are only read.

## Running

```
cp -R _build/dev/lib/spec_lint/ebin /tmp/cm_tool
TOOL_EBIN=/tmp/cm_tool SPEC_LINT_OSS=... SPEC_LINT_EXPANSION=... \
  OUT=/tmp/cm_out bench/clause_mapping/run.sh            # fixtures and all corpora
bench/clause_mapping/run.sh fixtures jason               # or a selection
bench/clause_mapping/table.sh /tmp/cm_out robust_a1 strict_a1
```

The fixtures alone: `elixir -pa TOOL_EBIN bench/clause_mapping/recompute.exs
fixtures OUT.json` prints one row per fixture function and, per typed
variant, the number of wrong exact claims or unsound brackets. The fifteen
corpora took 83 seconds (OTP 28.5.0.1).

## Limits

- The typed variants are not sound (E1-E3, R1-R2) and are not used.
- The replay is an oracle only where it reproduces the stored signature;
  elsewhere nothing is checked.
- Only `c24c235` runs the experiment. For 1.20.4 and `648b2a9` the
  structural classes rest on the source reading above and the product's
  per-adapter tests.
- A mapping is only as good as the debug info: a module without it has no
  mapping (`not determined`), and a clause with no line prints `line
  unknown`.
