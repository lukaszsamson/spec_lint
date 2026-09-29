# Clause-local translation-loss qualification

This is NEXT_STEPS.md "Next experiment", item 1, run on 2026-09-29 from
`10970dc` behind `clause_local_qualification: true`
(`--clause-local-qualification`), first with the default `false`.

**Decision (Close phase, 2026-09-29): adopted as the default, gating in both
profiles** (section "Decision" below). An independent adversarial review
found a reachability hole that the qualification would have exposed
(section "Independent review"); it was fixed for both settings before the
decision, and `--no-clause-local-qualification` restores the slice-wide
arrow prerequisites.

## What changes

Without the flag, an `SL001` `clause_conflict` needs the slice-wide
prerequisites `no_unsupported_loss`, `no_overlap`, `no_arrow_in_return` and
`no_arrow_polarity_argument`, plus `clause_contained` and `clause_reachable`.
An inexact arrow anywhere in the slice therefore blocks every clause of it.
In `Ash.Page.page_opts/1` the arrow is inside a struct field of `page()`.

With the flag, a clause-level finding has these prerequisites:

- `no_unsupported_loss`, kept;
- `no_overlap`, kept;
- `clause_contained_in_lo`, new, replacing both arrow prerequisites;
- `clause_reachable`, kept (since the review also decided by the
  compiler's own pattern and guard check, `SpecLint.Reachability`).

`clause_contained_in_lo` holds when the clause's whole stored domain tuple
is non-empty and a subtype of `tuple(D_lo)`. The comparison is tuple-wise
(the spec slice is itself a product of its argument bounds), never position
by position. The superseded prerequisites and their states are kept in the
finding's `data` (`superseded_prerequisites`), so one report shows both
readings. The slice-level `conflict` keeps the old prerequisites, because
its `U(D)` comes from applying the whole signature at `D_hi`.

Code: `SpecLint.Compare` (`contained_lo?` per contributing clause),
`SpecLint.Evidence` (carries it per clause), `SpecLint.Rules.ReturnConflict`
(the prerequisites), `SpecLint.Config`/`CLI`/`Run` (the flag) and the JSON
`config`. The finding's fingerprint does not depend on the flag. A baseline
entry written while the finding was blocked is listed under `gate_changed`
and does not acknowledge the finding once it gates (tested).

## Soundness argument

- **(a) Inputs.** `D_lo ⊆ D`. Every translation loss only shrinks `D_lo`.
  An inexact arrow has lower bound `none()`, so in a union it adds nothing,
  and inside a tuple or required field it empties that alternative. A loss
  therefore cannot make a clause look contained. If
  `I_k ⊆ D_lo` and `I_k` is non-empty, every input the clause accepts is in
  the spec domain.
- **(b) Returns.** `R_k` is the stored clause return, upper-bounded. The
  evidence class already requires it to be non-empty and neither top nor
  near-top. It must also be disjoint from `S_hi`, which over-approximates
  `S` by construction: an inexact arrow in the return is `fun(arity)` there.
  Measured in `Descr` (`Compiler.disjoint?`), two function types of the same
  arity are never disjoint. That holds even for `(integer -> integer)`
  against `(integer -> atom)`, and for `(integer -> none)`. Only an arity
  mismatch is disjoint, which is a real violation. So an arrow in the return
  can only yield a conflict when the clause returns a function of another
  arity, or a non-function.
- **Conclusion.** Any normal return of that clause, for inputs inside the
  spec, is outside the spec. The clause must return normally for some input,
  and whether it is reachable is still `clause_reachable`: blocked when the
  compiler's type checker, re-run over the function's debug info, reports a
  pattern or guard diagnostic in the function, or when the clause is
  possibly shadowed; unchecked otherwise. A dead clause the type checker
  cannot see (a contradictory numeric guard) is the residual risk. It is
  the risk the slice-wide policy already accepts on arrow-free slices; the
  qualification extends it to clauses of slices with an arrow elsewhere.

In the current `Compare`/`Evidence` pipeline, the class `clause_conflict`
already requires containment. That means `contained_lo? = true` whenever the
slice is approximate, and `D_lo = D_hi` when it is exact. So on every
emitted finding `clause_contained_in_lo` is `met`, and the measured effect of
the flag is exactly the removal of the two arrow prerequisites for
clause-level findings. The new prerequisite is recorded as the explicit
claim. It guards the rule against a future change of the containment logic
and also rejects an empty clause domain. Both halves are tested since the
review (`clause_local_test.exs`, "clause_contained_in_lo is checked, not
assumed"): `Compare.clause_containment/4` on an empty clause domain, and a
rule-level context whose contained clause has `contained_lo?: false`.

## Fixtures and tests

- **Stand-ins for the two witnessed omissions.** They are
  `SpecLint.OmissionFixtures.ClauseLocal` in
  `test/support/omission_fixtures.ex` (see `omissions/README.md`), pinned by
  the `@clause_local` table in `test/spec_lint/omissions_test.exs`. Each has
  a runtime witness and a control, checked by hand-written predicates:
  - `page_opts/1` (`Ash.Page.page_opts/1`): `false` and `nil` return
    `{:ok, false}` and `{:ok, nil}`, and the control `[limit: 1]` returns
    `{:ok, %Page{}}`. Class `clause_conflict`. Not gated without the flag
    (`no_arrow_polarity_argument`); gated with it.
  - `via/3` (`Oban.Registry.via/3`): `(:name, nil, :witness)` returns an
    inner 3-tuple, and the `nil` value is the control. Class
    `clause_conflict`. Gated either way.
- **Controls.** These are `SpecLint.Fixtures.ClauseLocal`, asserted in
  `test/spec_lint/clause_local_test.exs`. Every spec carries an inexact
  arrow. None gates with the flag, except `other_arity/1`:

| Control | Shape | With the flag |
| --- | --- | --- |
| `only_hi/1` | `pos_integer()` erased to `integer()`, lower bound `none()`; clause on `integer()` | containment unknown, so no SL001 (SL002 `possible_input_approximate`) |
| `overlapping/1` | two overloads sharing `false` in their lower bounds | `clause_conflict` on both slices, blocked by `no_overlap` |
| `impossible/1` | `D_lo` empty (erased refinement and inexact arrow), catch-all clause escapes | no SL001 (SL002 `possible_domain_escape`) |
| `same_arity/1` | inexact arrow return `(pos_integer() -> atom())`, clauses return 1-ary functions | no finding: not disjoint from `fun(1)` |
| `other_arity/1` | same spec, clause `:b` returns a 2-ary function | **gates**: a real violation, witnessed (`is_function(other_arity(:b), 2)`, control `:a` is 1-ary). Without the flag it is blocked by `no_arrow_in_return` |
| `gradual/1` | contained clause returning `dynamic()` (`apply/3`) | top-only, no finding |
| `near_top/1` | contained clause returning `dynamic(not :undefined)` (`Process.put/2`) | near-top, no finding |
| `redundant/1` | contained clause covered by an earlier `is_atom/1` clause | `clause_conflict`, blocked by `clause_reachable` (the clause is quoted with `generated: true`, so the type checker's diagnostic is suppressed and the shadowing check blocks it) |
| `Fixtures.Review.apply_it/2` | slice-level conflict with an inexact arrow argument | still blocked by `no_arrow_polarity_argument` |
| `ClauseLocalProbe.Dead.g/1` (review) | inexact arrow argument; clause `def g(:b = x) when is_integer(x)` can never match, stored as `(:b) -> {:error, :b}` and covered by no earlier clause | `clause_conflict`, blocked by `clause_reachable` with and without the flag (the compiler reports "this guard will never succeed"; `data.pattern_diagnostic_lines`). Before the fix it **gated with the flag**: a false positive. Runtime: `g(:b)` returns `:fine` |
| `ClauseLocalProbe.Dead.h/1` (review) | the same dead clause without an arrow | blocked by `clause_reachable`; before the fix it gated even without the flag |
| `ClauseLocalProbe.Index.idx/1` (review) | source clause 0 always raises and is dropped from the stored signature | gates (true positive, `idx(:b)` returns `{:error, :b}`); the finding names "stored signature clause #0", which is source clause 1 |

The three review probes are compiled out of process in the test (the
compiler warns about the dead clauses), so they are not in
`reports/fixtures.json`.

With `require_static_return: true`, the gradual `dynamic({:ok, false or
nil})` clause return of `page_opts/1` is `possible_gradual` (SL002, not
gated), with or without the flag. A gradual `R_k` whose upper bound is
informative and disjoint (`page_opts/1`, `via/3`) gates under the existing
Phase 1 decision (`require_static_return: false`). The gradual controls
above cover returns whose upper bound carries no evidence.

The fixtures report (`reports/fixtures.json`) was regenerated. It gains
these 11 functions, and the classes of the 83 earlier ones and the fixture
accuracy block are unchanged.

## Measurement

All reports come from one tool tree, frozen before the holdouts were run:
`provenance.tool.source_sha256 = fa106878…2e6e` in all 30 provenance files
of `reports/expansion/clause_local/{off,on}/`, and the tool revision is
`10970dc` with uncommitted changes. The `git diff` of `lib/`,
`test/support/` and `run.sh` taken at the freeze (sha256 `6a6010be…ca42`) is
byte-identical to the one committed. The runs are product-only
(`SPEC_LINT_PRODUCT_ONLY=1`), because the experiment report has no product
options (see `README.md`). Checks on the reports:

- **Flag off.** Every `off/` report equals the committed baseline report
  (`reports/NAME.spec_lint.json` or `reports/expansion/NAME.spec_lint.json`)
  once the config digest and the new config key are removed.
- **Flag on against flag off.** In every corpus the `on/` report equals the
  `off/` report except for finding prerequisites, `data`, `details`, gates
  and the exit code. The findings, their fingerprints and the ledger are
  identical.

Columns: SL001 findings, SL001 gates before (flag off) and after (flag on),
all gates after, and the product exit code before and after. "Arrow slices"
is the number of compared slices with an `arrow_polarity` loss anywhere,
which is the scope the qualification can reach.

| Corpus | Slices | Arrow slices | SL001 findings | SL001 gates before | SL001 gates after | All gates after | Exit before / after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| stdlib | 1,777 | 94 | 0 | 0 | 0 | 0 | 0 / 0 |
| jason | 20 | 7 | 0 | 0 | 0 | 0 | 0 / 0 |
| decimal | 46 | 1 | 0 | 0 | 0 | 0 | 0 / 0 |
| nimble_options | 5 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| mime | 5 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| plug | 86 | 2 | 0 | 0 | 0 | 0 | 0 / 0 |
| ecto | 165 | 75 | 0 | 0 | 0 | 0 | 0 / 0 |
| req | 87 | 55 | 0 | 0 | 0 | 0 | 0 / 0 |
| broadway | 30 | 12 | 0 | 0 | 0 | 0 | 0 / 0 |
| oban | 130 | 35 | 1 | 1 | 1 | 1 | 1 / 1 |
| phoenix_live_view | 12 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| ash | 992 | 220 | 1 | 0 | **1** | 1 | 0 / **1** |
| nx | 9 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| **Tuned subtotal** | 3,364 | 501 | 2 | 1 | 2 | 2 | |
| absinthe (fresh holdout) | 453 | 368 | 7 | 7 | 7 | 7 | 1 / 1 |
| tesla (fresh holdout) | 387 | 332 | 0 | 0 | 0 | 0 | 0 / 0 |

## Triage of every newly gating finding

There is exactly one:

- **`Ash.Page.page_opts/1`, slice 0, clause 0.**
  `ash/lib/ash/page/page.ex:13` (spec) and `:14` (clause), at pinned ash
  `164a4c0`. The prerequisites with the flag are `no_unsupported_loss`,
  `no_overlap`, `clause_contained_in_lo` met and `clause_reachable`
  unchecked; the superseded `no_arrow_polarity_argument` was blocked.
- **Judgment: true positive, witnessed.** The spec takes `page() | false |
  nil | Keyword.t()` and promises `{:ok, page()} | {:error, String.t()}`.
  The clause `def page_opts(term) when term in [false, nil], do: {:ok, term}`
  returns `{:ok, false}` or `{:ok, nil}`, and neither `false` nor `nil` is a
  `page()` (a `Keyset.t()` or `Offset.t()` struct). The runtime witness
  `elixir bench/corpus/holdout_witnesses.exs /tmp/spec-lint-expansion` was
  rerun for this experiment. It returned `{:ok, false}` and `{:ok, nil}` from
  the pinned Ash BEAM.
- **Caveat.** The function is `@doc false`, a custom NimbleOptions-style
  validator, where `{:ok, false}` and `{:ok, nil}` mean "no pagination". It
  is a real spec omission of an internal helper, not a user-facing bug.
- **The rest of the function also escapes (review).** The catch-all clause
  returns `{:ok, mod.to_options(value)}` from `validate_or_error/2`, a
  keyword list, never a page: on the pinned build `[limit: 1]` returned
  `{:ok, [limit: 1]}`, `[offset: 2, limit: 1]` returned
  `{:ok, [offset: 2, limit: 1]}` and `[after: "x", limit: 1]` returned
  `{:ok, [after: "x", limit: 1]}`. No input returns `{:ok, page()}`: the
  declared return is wrong as a whole, not only for `false` and `nil`.
  SpecLint does not report the catch-all (its stored domain is wider than
  the spec's and its payload is gradual), a silent false negative. The
  stand-in's in-spec control `[limit: 1] -> {:ok, %Page{}}` is therefore
  synthetic (`omissions/README.md`). The verdict for clause 0 stands.

No other finding changed gate state in any corpus, tuned or holdout.

## False positives

None were found among newly gating findings (0 of 1). Among the fixtures,
the one control that gates with the flag (`other_arity/1`) is a witnessed
real violation, and every negative control stays ungated.

Pre-existing gates the flag does not touch were also triaged for context.
They are not credited to the experiment:

- **`Oban.Registry.via/3`**: a true positive, witnessed earlier
  (`expansion_triage.md`).
- **`Absinthe.Blueprint.Input.parse/1`, clauses 1 to 7.** These are the
  fresh holdout's only gates, `absinthe/lib/absinthe/blueprint/input.ex:36`
  (spec `parse(any) :: nil | t`) and clauses `:41-82`. They are **true
  type-contract violations**. Each clause builds a struct such as
  `%Input.Integer{value: value}` and leaves `source_location` at its
  default, `nil`, while every `Input.*.t()` declares
  `source_location: Blueprint.SourceLocation.t()`, a struct
  (`blueprint/input/integer.ex:6-21`, and likewise in `float`, `null`,
  `string`, `boolean`, `list` and `object`). Running the pinned build,
  `Absinthe.Blueprint.Input.parse(1)` returned
  `%Absinthe.Blueprint.Input.Integer{value: 1, source_location: nil, ...}`.
  As with Req's `Response.new/1`, whether a default-`nil` struct field
  deserves a CI gate is a usability question, not a soundness one. These
  gates come from the existing policy (exact `clause_contained`, no arrow
  loss involved) and are identical with and without the flag.

## Do the fresh holdouts agree?

The implementation was frozen before either holdout ran with the flag, and
it was not changed afterwards. The freeze digest above is the one recorded
in both holdout provenance files.

- **Result.** Absinthe keeps 7 gates and tesla 0, with the flag off and on.
  There are no new gates, no lost gates and no false positives.
- **What it shows.** The holdouts do not contradict the tuned corpora. They
  cannot confirm a benefit either: before the flag, neither holdout had a
  single SL001 finding blocked by an arrow prerequisite
  (`holdout2_baseline.md`: "SL001 findings that did not gate: none"),
  although 368 and 332 of their compared slices carry `arrow_polarity`
  losses. The experiment has no statistical power on them.
- **Interpretation.** A gate is only reachable through an already reported
  `clause_conflict`, and the flag changes prerequisites, never evidence.
  Across 4,204 compared real-code slices (15 corpora) there are 9 SL001
  findings, and the flag moves one of them, `page_opts/1`.

## Review

**Self-review (experiment phase).** Mutation checks of the new tests: each
of these deliberate breakages of `ReturnConflict` made
`clause_local_test.exs`/`omissions_test.exs` fail:

- also dropping `no_overlap` (2 failures);
- ignoring `clause_reachable` (1);
- ignoring the flag (7);
- keeping `no_arrow_in_return` (2).

Two mutants survived then and were not reported: replacing
`Rule.state(contributing.contained_lo?)` by `:met`, and dropping the
non-empty condition of `contained_lo?`. Both are killed since the review.

## Independent review

An independent adversarial review (Close phase, 2026-09-29) attacked the
soundness argument, the triage, the witnesses and the evidence files. It
did not dispute that a translation loss only shrinks `D_lo` or that `S_hi`
stays an upper bound. Its findings and their outcomes:

| Finding | Severity | Outcome |
| --- | --- | --- |
| `clause_reachable` missed a clause whose guard contradicts its pattern (stored with its pattern domain and body return, covered by no earlier clause), so the flag gated a dead clause (`g/1`), and the slice-wide policy gated the arrow-free twin (`h/1`); the "never misses a clause the compiler reports" wording was false | medium | Fixed for both settings: `SpecLint.Reachability` re-runs the compiler's type checker (`Module.Types.warnings/6` through `SpecLint.Compiler.pattern_diagnostics/4`) over the debug info of every function with a clause conflict, and any pattern or guard diagnostic blocks `clause_reachable` for the function. A check that cannot run blocks under the qualification. Wording corrected in `ReturnConflict`, `Compare.shadowed/1` and DESIGN. Regression tests: the `g/1`/`h/1` probes, compiled out of process, with runtime witnesses |
| The reported clause index is the stored signature clause, not the source clause (a raising clause is dropped, equal returns merge) | low | The detail is now labelled "stored signature clause #k", and README, DESIGN and the `ReturnConflict` moduledoc say what the index and line mean. Mapping back to a source clause needs the checker's clause mapping, which the chunk does not store (DESIGN section 12). Regression test: the `idx/1` probe |
| `Ash.Query.apply_to/3` witness input is outside `Ash.Query.t()` | medium | Downgraded to probable: any query that loads a calculation is outside `t()` (`calculations: %{optional(atom) => :wat}`), and no in-domain error path was found (`holdout_triage.md`). The script now records whether each input is in the declared domain |
| `Ash.page/2` and `Policy.solve/1` witness inputs are outside their declared types | medium | Inputs repaired (`distinct: []`, `timeout: nil`; `subject` and the scenario lists), checked by `Support.query_t?/1`, `authorizer_t?/1` and `valid_keyset_page?/1`; both verdicts stand with in-domain inputs. Output: `reports/expansion/ash_integration_witnesses.json` |
| `page_opts/1` triage missed that the catch-all also escapes; the stand-in's control is synthetic | low | Documented here, in `holdout_triage.md` and in `omissions/README.md` |
| `clause_contained_in_lo` and its non-empty condition were untested (two surviving mutants) | medium | `Compare.clause_containment/4` extracted and tested on an empty domain; a rule-level test blocks a clause with `contained_lo?: false`. Mutants re-run: both killed, and so are three new ones (ignoring a compiler diagnostic, not blocking an unavailable check, checking no definitions) |
| DESIGN sections 4, 6 and 9.1 said arrow slices are excluded from SL001 unconditionally | low | Updated |
| NEXT_STEPS said results were uncommitted | low | Updated |
| `bench/corpus/README.md` said no real corpus has a clause conflict | low | Scoped to the original corpora |
| Provenance files held session and machine paths | low | `provenance.sh` writes the report placeholders (`$OSS`, `$ELIXIR`, `$COMPILER`, `$TMP`, `$SPEC_LINT`); the 40 committed provenance files were rewritten in place, with no hash changed |
| `mix spec_lint.baseline` accepted the option without documenting it | low | Documented, with the advice to write the baseline under the CI setting |
| Stray `erl_crash.dump` | low | Deleted (it was ignored and never committed) |

The reachability fix also changes the slice-wide policy: before it, a
clause conflict in a clause the compiler reports as unable to match gated
whenever the slice had no arrow. On the real-code corpora no gate depends
on it (the stdlib and holdout confirmation runs below, and the re-check of
`Oban.Registry.via/3`, `Ash.Page.page_opts/1` and
`Absinthe.Blueprint.Input.parse/1`, which report no diagnostic).

## Confirmation runs (final tree, default configuration)

After the decision was committed (`f71b657`), the stdlib and both fresh
holdouts were rerun product-only with no product arguments, so with the new
default and the compiler check of `clause_reachable`
(`reports/expansion/clause_local/default/`; `provenance.tool.source_sha256 =
14c684b7…82f2` in all three, tool revision `f71b657`).

| Corpus | Compared slices | SL001 findings | Gates | Exit | Against `on/` |
| --- | ---: | ---: | ---: | --- | --- |
| stdlib | 1,777 | 0 | 0 | 0 | identical report |
| absinthe (holdout) | 453 | 7 | 7 | 1 | same findings, fingerprints, prerequisites, data, gates and ledger; only the detail label "inferred clause" is now "stored signature clause" |
| tesla (holdout) | 387 | 0 | 0 | 0 | identical report |

The compiler check reports no pattern or guard diagnostic for
`Absinthe.Blueprint.Input.parse/1`, so its seven gates keep
`clause_reachable: unchecked`. The reports match the decision: no gate
moved on the holdouts, and the stdlib stays at zero gates.

## Decision

**Adopted: `clause_local_qualification` defaults to `true`, and a clause
conflict it qualifies gates in both profiles**, as every other SL001
`clause_conflict` does.

The rule set for the decision: default on only if every newly gating
finding on the fresh holdouts and tuned corpora is a triaged true positive
that survived review, and every negative control passes.

- **Newly gating findings.** One on 3,364 tuned-corpus slices,
  `Ash.Page.page_opts/1`, a witnessed true positive whose verdict the
  review confirmed (and found the rest of the function wrong too). None on
  the 840 fresh-holdout slices.
- **False positives.** 0 of 1 on real code.
- **Negative controls.** All pass: the nine experiment controls, and the
  review's dead-clause controls once `clause_reachable` consults the
  compiler. Before that fix one control (`g/1`) failed, so the fix was a
  precondition of the decision, not a follow-up.
- **Holdouts.** They agree and cannot disagree: neither had a clause
  conflict blocked by an arrow prerequisite, so the qualification moves
  nothing there. The decision rests on the argument and the controls, not
  on measured recall.
- **Why not review-profile only.** A profile split is for evidence that is
  useful but not trusted to fail CI (SL006). A qualified clause conflict
  has the same evidence and the same reachability prerequisite as an
  unqualified one; only a prerequisite that was irrelevant to the clause
  is dropped. Gating it in one profile only would treat equal evidence
  differently.
- **Why not off.** The argument is a proof over sound bounds, the only
  counterexample the review found was a reachability hole shared with the
  existing policy and is now closed, and the benefit, though small, is a
  real omission.
- **Limitation.** The measured benefit is one function. The qualification
  does not address the dominant unknown reasons (`top_only`,
  `no_counted_component`); see `compiler_counterexamples/`.
