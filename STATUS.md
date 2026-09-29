# SpecLint status

Date 2026-09-29. This covers Phase 0, Phase 1, the post-Phase 1 review
fixes (commit `1b0fe93`), the first external review (all five findings
closed: four fixes in `c4a8e18`, the corpus bundle in `3adadd4`), the
body-backend experiment (`ac3a75b`), the second external review, the
follow-up delivery, and the Close phase of the clause-local qualification
experiment (first section). `DESIGN.md` is the authoritative design, `EXPERIMENTS.md`
holds the measurements, and `README.md` is the user guide.

## Close phase (2026-09-29): clause-local qualification adopted

**Decision.** `clause_local_qualification` now defaults to `true`, and the
clause conflicts it qualifies gate in both profiles. An SL001 clause
conflict is qualified by its own clause: its whole domain must be inside
the spec's argument lower bounds (`clause_contained_in_lo`), and an arrow
elsewhere in the slice no longer blocks it. `--no-clause-local-qualification`
or `clause_local_qualification: false` restores the slice-wide arrow
prerequisites. Rationale and the decision rule are in
`bench/corpus/clause_local_qualification.md`, "Decision".

| Corpora | Compared slices | SL001 findings | SL001 gates, flag off → on | New gates triaged |
| --- | ---: | ---: | --- | --- |
| stdlib, 6 original libraries, 6 expansion projects (tuned) | 3,364 | 2 | 1 → 2 | `Ash.Page.page_opts/1`: true positive, witnessed |
| absinthe, tesla (fresh holdouts, frozen before the experiment) | 840 | 7 | 7 → 7 | none |

False positives among new gates: 0 of 1. Negative controls: all pass,
including the review's dead-clause controls. The holdouts had no clause
conflict blocked by an arrow prerequisite, so they could not confirm a
benefit; the decision rests on the soundness argument and the controls.
Confirmation runs with the final tree and the default configuration
(`reports/expansion/clause_local/default/`): stdlib 0 gates (exit 0),
absinthe 7 (exit 1), tesla 0 (exit 0), matching the flag-on measurement
finding for finding.

**Independent adversarial review.** Twelve findings, all resolved
(`clause_local_qualification.md`, "Independent review"):

- **`clause_reachable` missed dead clauses** whose guard contradicts their
  pattern (a false positive with the flag, and in the existing policy on
  arrow-free slices). It is now also decided by the compiler's own pattern
  and guard check, re-run over debug info (`SpecLint.Reachability`), for
  both settings.
- **Clause findings name the stored signature clause**, which the details
  now say ("stored signature clause #k").
- **`clause_contained_in_lo` is now tested**, including an empty clause
  domain.
- **Three Ash integration witnesses** used inputs outside the declared
  struct types. `page/2` and `Policy.solve/1` keep their verdicts with
  repaired inputs; `Query.apply_to/3` is downgraded to probable
  (`holdout_triage.md`).
- **`Ash.Page.page_opts/1`'s catch-all also escapes** (it returns a keyword
  list, never a page). SpecLint does not report it.
- **Provenance paths** now use placeholders, and the docs are corrected.

**Remaining open items.**

- `clause_reachable` is `unchecked`, not proven, when the type checker
  reports nothing: a dead clause it cannot see (a contradictory numeric
  guard, a clause only the Erlang compiler reports) could still gate. A
  per-source-clause reachability verdict in the checker chunk would close
  it (DESIGN section 12).
- The re-check blocks per function, not per clause, and findings cannot
  name their source clause or line, because the chunk does not store the
  source-to-stored clause mapping.
- `Ash.Query.apply_to/3` has no in-domain witness; `page_opts/1`'s
  catch-all is a silent false negative.
- Recall is unchanged in substance (gated recall on the nine known
  omissions is 0 of 9). The two compiler limits behind most misses now have
  minimal counterexamples in `bench/corpus/compiler_counterexamples/`.

## Follow-up delivery: broader evidence and build integrity

The six-project expansion adds 1,252 eligible functions and 1,260 spec
slices. All runs complete without unsupported/unavailable slices; 1,037
obligations remain unknown. There are 14 findings and one CI gate, a
confirmed return-shape omission in `Oban.Registry.via/3`. The actual Req
path-dependency consumer also passes. Full tables and source judgments are
in EXPERIMENTS.md and `bench/corpus/{expansion_triage,holdout_triage}.md`.
Do not treat a clean run as evidence that the project has accurate specs.

Build integrity now rejects unreadable owned-app inventories, corrupt BEAMs,
and BEAM filename/module mismatches with exit 2. A corrupt manifest falls
back to a valid `.app`; a valid empty manifest remains authoritative over a
stale `.app`. Regression tests cover all of these cases.

Benchmark changes enforce revision pins, retain complete compressed reports,
validate reduced report schemas, record compiler/tool/artifact hashes, and
fail on incomplete product runs. Body rebuilds use fresh output directories;
metrics distinguish gates, candidates, reports and unavailable analysis. All
nine stand-in omission fixtures now have direct runtime assertions. The
patched body-fixture rerun does not change the decision against a production
body backend. See NEXT_STEPS.md for the completed plan and validation.

## What exists

`mix spec_lint` checks `@spec` declarations against the signatures the
Elixir compiler infers. It reads compiled BEAM files. It runs no Dialyzer,
needs no PLT, never starts the application, and never calls project
functions.

It has about 8,800 lines in `lib` and 5,800 in `test`:

| Component | Module | State |
| --- | --- | --- |
| Compiler adapter | `SpecLint.Compiler`, `SpecLint.Compiler.V121` | Pinned to Elixir 1.21.0-dev `c24c235`, checker chunk `elixir_checker_v10`. Preflight, chunk decoder, every `Descr` call, a copy of `apply_infer/2` with its 16-clause cutoff, a canonical `Descr` serialisation and a printer. |
| BEAM reader | `SpecLint.Beam`, `SpecLint.Project` | Reads `ExCk`, `Dbgi` specs, types and debug info (including `use`-injected overridable defaults). Handles owned ebins, umbrella children and exclude globs, and checks every module the build lists has its BEAM file (compile manifest, or `<app>.app`). |
| Translator | `SpecLint.Translate`, `SpecLint.Bound`, `SpecLint.TypeCache` | Turns spec AST into `{lo, hi}` bounds with loss records (the section 6 kinds plus `map_key_widened`) and integer intervals. `expand_opaque` is optional. |
| Comparison | `SpecLint.Compare` | Raw per-slice relations: application, extra and missing, containment per clause (against `D_hi` and `D_lo`), overlap (certain or unknown), top-only, near-top, clause shadowing, and the dynamic probe. |
| Reachability | `SpecLint.Reachability` | For functions with a clause conflict only: re-runs the compiler's type checker over debug info and keeps its pattern and guard diagnostics, which block `clause_reachable`. |
| Evidence | `SpecLint.Evidence` | The DESIGN 3.1 classifier, steps 1 to 9: union level plus per-clause evidence, the F1 subtraction check with widening, near-top handling, and gradual payloads. |
| Rules | `SpecLint.Rules.*` | SL001 (slice and clause conflict), SL002 (informational), SL003, SL004 and SL005 (hints, off by default), SL006, SL007 (a stub, since no backend exists), SL008. |
| Policy | `SpecLint.Policy` | Gating by evidence for the `review` and `soundness` profiles, `--warnings-as-errors` (which never touches SL008), and the coverage policy. |
| Coverage | `SpecLint.Coverage` | Per-slice inventory and a ledger with denominators. Unknown obligations are counted by reason, and regressions are checked against the baseline inventory, including specs removed from functions that are still exported and overloads removed from multi-clause specs (`unanalysed`), but not user overrides deleted in favour of a `use`-injected default. |
| Baseline | `SpecLint.Baseline` | Structural fingerprints, acknowledgements with reason, owner and expiry, the gate state each finding was written with (`blocked`, `gate_changed`), inventory acknowledgements, stale detection (only for analysis that happened, plus compared entries whose slice vanished), regeneration that keeps what was not analysed, and adapter reconciliation per file and per entry (`pending_reconciliation`). |
| Run | `SpecLint.Run` | One run with exit code 0, 1 or 2. Completion is complete, partial or incomplete. Coverage is checked whatever rules are selected. |
| Reports | `SpecLint.Report.Console`, `SpecLint.Report.Json`, `SpecLint.Explain` | Console output, a versioned deterministic JSON envelope written atomically, and `--explain`. |
| Mix tasks | `mix spec_lint`, `mix spec_lint.baseline` | Options are parsed before compile. Compile failure exits 2. With `--format json` to stdout, compiler output goes to stderr. |
| Bench | `bench/experiment.exs`, `bench/run_on_ebin.exs`, `bench/body_experiment.exs`, `bench/triage/` | The SL002 experiment runner, the product pipeline run over explicit ebins (OSS corpora), the body-backend experiment (runs only under a compiler carrying the `warnings/7` hook, `bench/corpus/warnings7.patch`; `bench/corpus/body_run.sh`), and the Phase 0 triage probes (`per_clause.exs`, `near_top.ex`). `run.sh` and `body_run.sh` run under bash 3.2 or later. |

The tests cover the following. Some are unit tests, some are fixture
corpora (`test/support`), and one is a consumer integration project built
in a separate OS process:

- translation;
- the application-rule copy;
- relations;
- evidence classes on 25 experiment fixtures;
- rules and policy;
- fingerprint stability: line changes, function reordering, spec clause
  reordering, recompilation, a fresh VM, alias and variable renames, and
  union reordering;
- baseline decisions;
- exit codes, including canaries for an internal failure and a checker
  chunk version mismatch;
- JSON determinism.

## How to run

Toolchain: Elixir 1.21.0-dev (`c24c235`) from `~/elixir` on `PATH`,
Erlang/OTP 28.

```
mix spec_lint                                 report, exit 0
mix spec_lint --ci                            gate new findings (review profile)
mix spec_lint --ci --profile soundness
mix spec_lint --explain MyApp.Store.lookup/1
mix spec_lint --format json --output spec-lint.json
mix spec_lint --format json > spec-lint.json  stdout carries only the JSON
mix spec_lint.baseline                        write .spec_lint_baseline.json
```

To run on a project SpecLint cannot be added to, such as the OSS corpora:

```
MIX_ENV=test mix run bench/run_on_ebin.exs -- --ebin DIR [--code-path DIR ...] \
  --root DIR [--ci] [--format json --output FILE] [--write-baseline FILE]
MIX_ENV=test mix run bench/experiment.exs -- --ebin DIR ... --label NAME --out FILE.json
```

Quality gates, all green on the Close-phase tree (2026-09-29):

```
mix format --check-formatted
mix credo --strict            # no issues (70 checks)
mix test                      # 311 tests, 0 failures (includes test/integration)
mix dialyzer                  # 0 errors (PLT in priv/plts)
mix spec_lint --ci            # self-check: 276 slices compared, exit 0
```

## Measured numbers

All measurements were made on the pinned toolchain. Details are in
`EXPERIMENTS.md`.

**Coverage.** The corpora were the stdlib (elixir, eex, ex_unit, iex,
logger, mix) and six OSS libraries: jason, decimal, nimble_options, mime,
plug and ecto. On real code that is 2,038 spec'd functions and 2,104
slices, with 0 unsupported and 0 unavailable. The stdlib alone has 1,711
functions and 1,777 slices: 896 translate exactly and 881 approximately.

**Runtime.** About 2.5 s of analysis for the stdlib, and under 0.7 s for
each OSS library.

**SL002.** On real code, 2 candidates remain after the fixes. Both are
refuted false positives, and precision is 0 of 2 (0 of 9 before the fixes).
None of the 9 confirmed real omissions reaches `structured_possible`.
SL002 is therefore informational.

**SL001 `clause_conflict`.** It has 0 real-code candidates, so real-code
precision is unmeasured (0/0). On the fixtures it detects 4 of 4 with 0
false positives. The overlap tag blocks `pick/1`, and the reachability
check blocks the redundant-clause fixture `shadowed/1`.

**Recall on the 9 known real omissions.** 0 gated, 2 reported
(`Ecto.Query.Builder.Join.escape/3` and `quoted_type/2`, both as
`possible_domain_escape`). The remaining 7 are `unknown`, mostly because
inference is top-only.

**Body backend experiment** (EXPERIMENTS.md "Body backend experiment",
reports in `bench/corpus/reports/body/`). The body is type-checked under
each spec slice's domain through the `warnings/7` hook, on a patched
`c24c235` build (`bench/corpus/warnings7.patch`).
- Gating recall on the 9 known omissions goes from 0 to 1
  (`Ecto.Query.Builder.quoted_type/2`). Reported recall stays 2 of 9.
- It found one new real omission, `Ecto.Changeset.apply_changes/1`
  (report-only).
- It added 2 fixture false positives, 1 after the redundancy guard
  (`display/1`).
- It added no false positive on 297 real-code slices (decimal, plug, ecto).
- 18 obligations move from `unknown` to `none`, but only 5 are
  established (`U(D)` within `S_lo`: `Plug.Conn.get_cookies/1`,
  `get_resp_cookies/1`, `Ecto.put_meta/2`, `Ecto.Changeset.constraints/1`,
  `validations/1`); the other 13 (11 `Plug.Conn` struct updates,
  `add_error/4`, `prepare_changes/2`) have inexact spec returns and are
  compatible at available precision only. The reports now record
  `established` and `return_exact` per mode.
- Each slice costs about one module re-check: 1.7 s of body calls over
  decimal, plug and ecto, against 1.2 s for the whole signature analysis.
- The 8 misses: 5 are top-only returns (through helpers analysed under
  default domains: `Decimal.compare/2`, `cmp/2`; through generic
  `Enum`/`Map` calls: `Plug.Conn.Query.decode/4`, `Ecto.Repo.Assoc.query/4`,
  `Ecto.Repo.Preloader.query/7`); 2 are not top-only but leave only an
  uncounted component (`Ecto.Changeset.apply_action/2`, a subtraction
  payload through `apply_changes/1`; `Plug.Conn.merge_private/2`, a
  negated struct field through `Enum.into/2`), with input approximation on
  top; 1 is input approximation (`Ecto.Query.Builder.Join.escape/3`).
- Decision: **not adopted** (DESIGN sections 7 and 11).

**Stdlib before and after the review fixes.** Function classes are
unchanged except for `DateTime.from_iso8601/2,3`, which moved from
`unknown` to report-only `possible_domain_escape` because of the F1
widening check. That is a `float()` offset from arithmetic, the known
false-positive shape.

`mix spec_lint --ci` on the stdlib:

| | Findings | Gating | Exit |
| --- | --- | --- | --- |
| Before | 31 SL002 | 0 | 0 |
| After | 33 SL002 | 0 | 0 |

Unknown obligations on the stdlib, by reason: top_only 796,
no_counted_component 239, near_top 29.

**Fixtures.** 25 of 25 classes are as expected under both
`require_static_return` settings.

| `require_static_return` | Detected | Suppressed | False positives | True negatives |
| --- | --- | --- | --- | --- |
| `false` | 9 | 2 | 0 | 14 |
| `true` | 3 | 8 | 0 | 14 |

## Decisions

Each decision is recorded in DESIGN; the section is given in parentheses.

- **SL002 is informational** (sections 4 and 11, Phase 0 and the Phase 1
  rerun). It is reported in both profiles and gated only by
  `--warnings-as-errors`. It will be revisited when at least 10 candidates
  have been reviewed, precision is at least 80%, and at least 3 omissions
  are confirmed.
- **`clause_conflict` gates in both profiles** (section 4). The
  unreachable-clause prerequisite is approximated from the stored clause
  domains (3.1 step 7). A possibly shadowed clause is blocked. The check
  over-blocks guarded clauses: 23 stdlib clauses are flagged, none of them
  a conflict.
- **`require_static_return` defaults to `false`** (section 4). The measured
  cost of `true` is lost recall on the gating class, with no precision
  gain.
- **SL001 gating prerequisites** are: no `unsupported_construct` loss, no
  overlap tag (certain or unknown), no arrow in the return, and no
  argument with an `arrow_polarity` loss (sections 4 and 6).
- **Fingerprints** hash the translated bounds and the normalised loss
  records, not the raw spec AST (9.1). Cosmetic spec edits therefore keep
  acknowledgements. Refinements the lattice erases inside a type are not
  distinguished.
- **Stale detection only covers analysis that happened** (section 9). It
  never runs on partial or incomplete runs, never covers rules that did
  not run, and never covers slices or modules that are now unsupported or
  unavailable.
- **Coverage is independent of rule selection**, and
  `--warnings-as-errors` never changes SL008 (sections 4 and 9.1).
  `fail_on_regression: false` exempts regressions only. A slice that was
  never compared still needs an acknowledgement (9.1).
- **An unsupported checker chunk** (`unsupported_chunk`) is a preflight
  failure: the run is incomplete, CI exits 2, and it cannot be
  acknowledged (5.1).
- **SL006 ignores top-only and near-top inference.** Such cases are
  recorded in the ledger as unknown (section 4).
- **The evidence class list is the one implemented** (section 4). It adds
  `clause_conflict`, `possible_gradual`, `unexpected_return`,
  `unsupported` and `unavailable`.
- **Deferred:** inline suppression, `--no-compile` and path filters
  (section 8).

## Open findings from external review (2026-09-28)

None. Both reviews are closed; the second one is listed under "Delivered
in this phase". One item is left to the maintainer: two earlier commits
(`c4a8e18`, `ac3a75b`) carry a different `Co-Authored-By` trailer than the
review expected, and correcting them would rewrite published history.

## Delivered in this phase (second external review)

Every finding has a regression test; DESIGN 9.1 records the decisions.

1. **An ebin that lost its BEAM files passed CI as "0 specs" (high).**
   `SpecLint.Project.check_build_paths/1` returns
   `{:error, :missing_beams}` when a module the build lists has no BEAM
   file: the Elixir compile manifest of a Mix project (Mix does not rebuild
   the BEAM files, its manifest says the build is up to date), or else
   `<app>.app`. The run is a configuration error (exit 2). As a second
   line, a `compared` baseline entry whose slice is absent from the whole
   inventory is a stale inventory entry. Tests: `SpecLint.CoverageTest`
   "an ebin missing BEAM files its .app lists ...",
   `SpecLint.Integration.BuildAndCoverageTest` (BEAM files deleted with
   and without the `.app` file: exit 2).
2. **A report-only SL001 in the baseline suppressed it once it gated
   (medium).** Each baseline finding records its blocked prerequisites
   (`"blocked"`); an entry written blocked does not acknowledge an SL001 or
   SL003 issue whose prerequisites are now met. The issue is new and the
   entry is listed under `gate_changed` (console and JSON). Test:
   `SpecLint.BaselineTest` "a report-only finding in the baseline does not
   acknowledge it once it gates".
3. **Regeneration while a module or slice was unavailable dropped its
   acknowledgements (medium).** `Baseline.build/5` keeps the previous
   findings of slices and modules that are now unsupported, unavailable or
   unanalysed (the rule stale detection uses), and the compared inventory
   entries of modules unavailable as a whole. Test: `SpecLint.BaselineTest`
   "regenerating while a module is unavailable keeps its
   acknowledgements".
4. **Deleting an override of a `use`-injected default was a false
   `spec_removed` (medium).** An export whose debug-info definition carries
   `from_super: false` (the compiler's marker for an overridable default
   that was not overridden) is a deleted user definition, not a regression.
   Test: `SpecLint.CoverageTest` "deleting an override of a use-injected
   default is not a regression" (a `use GenServer` module).
5. **Losing one overload passed CI although DESIGN 9 says it is a
   violation (medium, and the low finding on the same point).**
   Implemented as section 9 says: a function with fewer in-scope spec
   clauses than a slice the baseline lists as compared gets an `unanalysed`
   entry (`spec_clause_removed`), a regression. The first fix's exemption
   is removed from DESIGN 9.1, the Coverage moduledoc and the README. Test:
   `SpecLint.CoverageTest` "removing one overload while another stays
   analysed is a regression" (one overload removed, and overloads merged).
6. **Overclaims in the body-experiment write-up (two medium findings).**
   "18 obligations established" is restated as 5 established and 13
   compatible at available precision, from the new `established` and
   `return_exact` fields (reports regenerated; no other field changed).
   "7 of the 8 misses are top-only" is restated as 5 top-only and 2 not
   top-only; "together they cover 7 of the 8" is restated as removing one
   blocker in 7, with at most 4 (realistically 3) gateable.
7. **Low findings.** An explicit `--baseline` or `baseline:` path that does
   not exist is a configuration error (exit 2; `SpecLint.RunTest` and the
   build integration test). `mix spec_lint.baseline --output PATH` runs
   against `PATH` (integration test). `pending_reconciliation` is cleared
   when a kept entry's own adapter is the running one (`SpecLint.BaselineTest`
   "a pending entry regenerated under its own adapter acknowledges again").
   The omission fixtures' claim is qualified to class and detection, with
   the reason differences of `apply_action/2` and `quoted_type/2` recorded
   in `bench/corpus/omissions/README.md`. `run.sh` and `body_run.sh` no
   longer need bash 4 (both regenerated the reports under `/bin/bash`
   3.2.57). The fork and branches holding `c24c235` and `b88a257a3` are
   documented, and the hook is committed as `bench/corpus/warnings7.patch`.
   The Phase 0 triage probes are committed under `bench/triage/`, and every
   scratchpad path in EXPERIMENTS.md is marked non-durable. The
   integration tests use `SpecLint.ProjectFixture` (system temporary
   directory). README documents `lost_analysis` in the ledger. This file's
   counts are corrected.

## Fixed findings from the first external review

Each fix has end-to-end regression tests; DESIGN section 9.1 records the
decisions.

0. **Benchmark evidence lived only in the session scratchpad.** It is now a
   reproducible bundle under `bench/corpus/`: pinned corpus revisions and
   commands (`README.md`), `run.sh` to regenerate the normalised reports in
   `reports/` (all regenerated at this revision; `stdlib.json` stored in
   reduced form), and the nine real omissions as executable reproducers
   (`test/support/omission_fixtures.ex`, `test/spec_lint/omissions_test.exs`,
   `bench/corpus/omissions/README.md`). The test pins the current class of
   each: 7 `unknown` and 2 `possible_domain_escape`, gating recall 0 of 9.

1. **Spec removal bypassed coverage regression (high).** Coverage now
   compares the baseline inventory with the current exports
   (`SpecLint.Coverage.lost_analysis/2`). A compared slice whose function
   is still exported but has no spec in scope is an `unanalysed` entry
   (`spec_removed`), an SL008 finding and a regression (exit 1 in CI, or a
   coverage violation naming the MFA when SL008 is not selected). A deleted
   or no longer exported function is not a regression. Regenerating the
   baseline acknowledges the removal. Tests:
   `SpecLint.CoverageTest` "removing a @spec while keeping the function is
   a coverage regression" and "a spec that is now out of scope ...", and
   `SpecLint.Integration.BuildAndCoverageTest` (consumer project,
   `mix spec_lint --ci` exits 1 with SL008 on `Consumer.greet/1`).
2. **Old-adapter acknowledgements carried across a regeneration (medium).**
   Baseline findings are checked for adapter compatibility per entry.
   Entries of disabled rules from another adapter are kept with
   `"pending_reconciliation": true`, never count as baselined when the rule
   is re-enabled, are never stale, and are reported under
   `pending_reconciliation`. Tests: `SpecLint.BaselineTest` "a disabled
   rule's entries from another adapter are pending, never baselined" (the
   review's repro), "an entry without its own adapter inherits the
   file's", and "adapter change with a rule off, end to end".
3. **Unsupported sibling overloads dropped from overlap (medium).** An
   unsupported sibling makes a slice's overlap `unknown`, which blocks
   SL001 and SL003, unless the upper bounds of whatever of its arguments
   translate (`SpecLint.Translate.argument_bounds/2`) show it disjoint.
   Tests: `SpecLint.CompareTest` (three comparator and analysis tests),
   `SpecLint.TranslateTest` "argument bounds of an unsupported slice",
   `SpecLint.RulesTest` "SL001 with an unsupported sibling overload is
   gated only when shown disjoint".
4. **Missing build directory reported as zero specs.**
   `SpecLint.Project.check_build_paths/1` returns
   `{:error, :missing_build_path}` for an owned app whose ebin does not
   exist; the run is a configuration error (exit 2). An existing empty
   ebin exits 0 with "0 specs checked". Tests: `SpecLint.CoverageTest`
   "build directories", and `SpecLint.Integration.BuildAndCoverageTest`
   (exit 0 on an empty ebin, exit 2 on a removed one).

Wording: the analysis is conservative with tested gating prerequisites and
documented limitations. "Sound" is not claimed.

## Known limitations

- **Signature backend only.** There is no body analysis, so SL007 and
  `analysis: :bodies` exit 2. The body-backend experiment measured what
  body analysis would add (1 of 9 known omissions gated) and it was not
  adopted (EXPERIMENTS.md "Body backend experiment"). The binding
  constraints are compiler inference (helpers under default domains,
  generic `Enum`/`Map` signatures) and translation input approximation.
  Gating recall on known real omissions is 0 of 9.
- **Spec slices are positional.** Removing any one overload of a
  multi-clause spec is reported against the last slice index
  (`spec_clause_removed`), and reordering spec clauses changes the
  fingerprints of the findings on them.
- **Missing BEAM detection relies on a Mix internal.** The compile
  manifest is read with `Mix.Compilers.Elixir.read_manifest/1` of the
  pinned toolchain. Without it only `<app>.app` is checked, which Mix
  rewrites from the BEAM files present, so deleting both the BEAM files
  and the `.app` file is then caught only as stale inventory entries
  (a warning), not as exit 2. `bench/run_on_ebin.exs` checks `<app>.app`
  only.
- **Gate state covers prerequisites, not profiles.** A baseline entry
  records the prerequisites that blocked it, not the profile it was
  written under: an SL006 acknowledged under `soundness` (report-only)
  still acknowledges it under `review` (gated). Entries written before
  this phase have no `blocked` field and acknowledge as before.
- **Top-only inference hides most evidence.** On the stdlib, 913 of 1,777
  slices are top-only.
- **One pinned compiler revision.** Every internal used (`Descr`, the
  `ExCk` layout, `apply_infer/2`) is `@moduledoc false` and can change
  without notice. Any other compiler is reported as unsupported.
- **Reachability is approximated.** The compiler's redundancy verdict is
  not in the chunk, so the shadowing check over-blocks clauses whose
  earlier clauses are narrowed by guards.
- **Translation losses.** `integer_refinement_erased` makes most struct
  APIs (`Decimal.t()`, `Plug.Conn.t()`) input-approximate. Opaque remote
  types are `term()` unless `expand_opaque` is on. Overlapping overloads
  follow no validated semantics and are never gated.
- **Real-code precision of `clause_conflict` is unmeasured** (0
  candidates). The first confirmed false positive reopens its gating
  decision.
- **Minor gaps.** Message printing of nested negations is simplified, but
  it is presentation only. A module whose checker chunk version mismatches
  but that has no in-scope specs is not flagged. Umbrella aggregation
  is covered by `SpecLint.Integration.CiQualificationTest` (a two-child
  umbrella consumer). With no debug info the console and the summary line
  still say "0 specs checked: no eligible specs found" next to the SL008
  `missing_metadata` findings; the findings and the exit code are right,
  the wording is misleading.

## Next steps

**Next investment (per the external review): compiler inference, not a
body backend.** Body analysis did not improve recall materially (gated
0 to 1 of 9, reported 2 to 2), so it is not implemented or qualified. What
blocks the 8 misses is inference in the compiler; in the order of the
misses each would unblock (DESIGN section 11 has the same list):

1. **Parametric signatures for `Enum.map/2`, `Enum.reduce/3`,
   `Enum.into/2` and `Map.new/1`**: `Plug.Conn.Query.decode/4`,
   `Ecto.Repo.Assoc.query/4`, `Ecto.Repo.Preloader.query/7` (top-only
   today) and `Plug.Conn.merge_private/2`.
2. **Call-site-sensitive inference of local helpers and same-module
   callees**: `Decimal.compare/2` (the `error/4` macro and the private
   `handle_error/4`), `Decimal.cmp/2` (delegates to `compare/2`) and
   `Ecto.Changeset.apply_action/2` (through `apply_changes/1`).
3. **Recursive definitions inferred to a fixed point** instead of
   `dynamic()` at the self-call: `Ecto.Query.Builder.Join.escape/3`,
   `quoted_type/2`, and `unextract/3` under `Preloader.query/7`.
4. **Clause reachability per source clause in the checker chunk**: the
   23 over-blocked guarded stdlib clauses, and the body run's `name/1`
   fixture false positive.

Even with items 1 and 2, at most 4 of the 8 become gateable (realistically
3: `decode/4`, `Assoc.query/4`, `Preloader.query/7`), because input
approximation caps `Decimal.compare/2`, `merge_private/2` and
`apply_action/2` (and probably `cmp/2`). The follow-up experiment narrows the SpecLint-side recommendation:
a larger sound input lower bound alone cannot contain any of the 33
contributing stored clause domains in the nine fixtures, because none is
contained even in the input upper bound. Four fixture slices already have
exact input translation. See `bench/corpus/precision_ceiling.md`; this is
not a result about refined body signatures or all OSS code.


The expanded cohort changes the immediate experiment priority. Before a
broad compiler investment, investigate whether translation-loss prerequisites
can be qualified per clause: `Ash.Page.page_opts/1` has a witnessed literal
input/return omission, but an arrow elsewhere in the input union blocks its
SL001 gate. Prove that the relevant clause bounds remain sound, retain
contravariant-arrow and overlap negative controls, and validate on a fresh
holdout. Do not globally remove `no_arrow_polarity_argument`. The other two
witnessed Ash reports are SL002 and do not justify gating that rule.

Then, in order:

1. **Upstream API request.** Use the proposal in EXPERIMENTS.md "Minimal
   compiler API": `Module.Types.infer_under_domains/7` (only the targets
   and what they reach), signatures in stored form, reachability per
   source clause, diagnostics, and a `Module.Types.capabilities/0`
   version. Also ask for a stable, documented reader for the `ExCk`
   chunk and for the compile manifest's module list.
2. **SARIF output** next to the console and JSON reporters. Map rule IDs,
   evidence and fingerprints (as `partialFingerprints`) and the baseline
   state (as `baselineState`).
3. **Caching under `_build`**, keyed as DESIGN 9 "Cache keys" says (chunk
   contents, resolved remote types, tool and adapter versions, config
   digest; not the BEAM md5). Keep JSON byte identical.
4. **Additional adapters.** One module per qualified compiler revision
   (the next 1.21 development tips, then 1.21.0), each with the
   differential tests for `apply_infer/2`, a published support matrix and
   the stdlib regression.
5. Stdlib dogfooding: migrate the prototype's 68-entry exclusion list to a
   fingerprinted baseline.
6. Re-run the SL002 experiment whenever the classifier or containment
   changes (DESIGN section 12).
7. Recursion, mutual recursion and widening fixtures (DESIGN 7 item 5)
   were not built, because the body backend was not adopted; build them
   if it is revisited.
