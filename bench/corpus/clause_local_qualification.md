# Clause-local translation-loss qualification

This is NEXT_STEPS.md "Next experiment", item 1, run on 2026-09-29 from
`10970dc`. It ships behind `clause_local_qualification: true`
(`--clause-local-qualification`). The default is `false`, and nothing here
changes the default policy. The Close phase decides whether to adopt it.

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
- `clause_reachable`, kept.

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
  and whether it is reachable is still `clause_reachable`: an approximation
  that is unchecked, or blocked when the clause is possibly shadowed.

In the current `Compare`/`Evidence` pipeline, the class `clause_conflict`
already requires containment. That means `contained_lo? = true` whenever the
slice is approximate, and `D_lo = D_hi` when it is exact. So on every
emitted finding `clause_contained_in_lo` is `met`, and the measured effect of
the flag is exactly the removal of the two arrow prerequisites for
clause-level findings. The new prerequisite is recorded as the explicit
claim. It guards the rule against a future change of the containment logic
and also rejects an empty clause domain.

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
| `redundant/1` | contained clause covered by an earlier `is_atom/1` clause | `clause_conflict`, blocked by `clause_reachable` |
| `Fixtures.Review.apply_it/2` | slice-level conflict with an inexact arrow argument | still blocked by `no_arrow_polarity_argument` |

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

No independent reviewer was available to this run. The review was
adversarial self-review plus mutation checks of the new tests: each of these
deliberate breakages of `ReturnConflict` made
`clause_local_test.exs`/`omissions_test.exs` fail:

- also dropping `no_overlap` (2 failures);
- ignoring `clause_reachable` (1);
- ignoring the flag (7);
- keeping `no_arrow_in_return` (2).

An independent adversarial review of the soundness argument is still
recommended before adoption, in particular of the claim that every
translation loss only shrinks `D_lo`. That claim is inherited from the
translator's existing bound tests, not re-proved here.

## Summary for the Close phase

- **Benefit.** +1 witnessed true gate (`Ash.Page.page_opts/1`) on the tuned
  corpora, 0 on the fresh holdouts, and 0 false positives anywhere.
- **Controls.** All negative controls hold. A function returned at another
  arity than an inexact arrow return now gates, which is correct.
- **Risk.** Low. The argument depends only on `D_lo` being a sound lower
  bound and `S_hi` a sound upper bound, which the translator already
  guarantees and tests. The flag moves no evidence class and no
  fingerprint.
- **Limitation.** The measured benefit is one function. The flag does not
  address the dominant unknown reasons (`top_only`, `no_counted_component`).
  Adoption would be justified by its soundness and zero observed noise, not
  by recall.
