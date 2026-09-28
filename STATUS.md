# SpecLint status

Date 2026-09-28. This covers Phase 0, Phase 1, the post-Phase 1 review
fixes (commit `1b0fe93`) and the fixes for four of the five external
review findings (the commit after `6754fe3`). `DESIGN.md` is the authoritative design,
`EXPERIMENTS.md` holds the measurements, and `README.md` is the user guide.

## What exists

`mix spec_lint` checks `@spec` declarations against the signatures the
Elixir compiler infers. It reads compiled BEAM files. It runs no Dialyzer,
needs no PLT, never starts the application, and never calls project
functions.

It has about 8,000 lines in `lib` and 4,000 in `test`:

| Component | Module | State |
| --- | --- | --- |
| Compiler adapter | `SpecLint.Compiler`, `SpecLint.Compiler.V121` | Pinned to Elixir 1.21.0-dev `c24c235`, checker chunk `elixir_checker_v10`. Preflight, chunk decoder, every `Descr` call, a copy of `apply_infer/2` with its 16-clause cutoff, a canonical `Descr` serialisation and a printer. |
| BEAM reader | `SpecLint.Beam`, `SpecLint.Project` | Reads `ExCk`, `Dbgi` specs, types and debug info. Handles owned ebins, umbrella children and exclude globs. |
| Translator | `SpecLint.Translate`, `SpecLint.Bound`, `SpecLint.TypeCache` | Turns spec AST into `{lo, hi}` bounds with loss records (the section 6 kinds plus `map_key_widened`) and integer intervals. `expand_opaque` is optional. |
| Comparison | `SpecLint.Compare` | Raw per-slice relations: application, extra and missing, containment per clause, overlap (certain or unknown), top-only, near-top, clause shadowing, and the dynamic probe. |
| Evidence | `SpecLint.Evidence` | The DESIGN 3.1 classifier, steps 1 to 9: union level plus per-clause evidence, the F1 subtraction check with widening, near-top handling, and gradual payloads. |
| Rules | `SpecLint.Rules.*` | SL001 (slice and clause conflict), SL002 (informational), SL003, SL004 and SL005 (hints, off by default), SL006, SL007 (a stub, since no backend exists), SL008. |
| Policy | `SpecLint.Policy` | Gating by evidence for the `review` and `soundness` profiles, `--warnings-as-errors` (which never touches SL008), and the coverage policy. |
| Coverage | `SpecLint.Coverage` | Per-slice inventory and a ledger with denominators. Unknown obligations are counted by reason, and regressions are checked against the baseline inventory, including specs removed from functions that are still exported (`unanalysed`). |
| Baseline | `SpecLint.Baseline` | Structural fingerprints, acknowledgements with reason, owner and expiry, inventory acknowledgements, stale detection (only for analysis that happened), and adapter reconciliation per file and per entry (`pending_reconciliation`). |
| Run | `SpecLint.Run` | One run with exit code 0, 1 or 2. Completion is complete, partial or incomplete. Coverage is checked whatever rules are selected. |
| Reports | `SpecLint.Report.Console`, `SpecLint.Report.Json`, `SpecLint.Explain` | Console output, a versioned deterministic JSON envelope written atomically, and `--explain`. |
| Mix tasks | `mix spec_lint`, `mix spec_lint.baseline` | Options are parsed before compile. Compile failure exits 2. With `--format json` to stdout, compiler output goes to stderr. |
| Bench | `bench/experiment.exs`, `bench/run_on_ebin.exs` | The SL002 experiment runner, and the product pipeline run over explicit ebins (OSS corpora). |

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

Quality gates, all green after the external review fixes:

```
mix format --check-formatted
mix credo --strict            # no issues
mix test                      # 232 tests, 0 failures (includes test/integration)
mix dialyzer                  # 0 errors (PLT in priv/plts)
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

None.

## Fixed findings from external review

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
  `analysis: :bodies` exit 2. Containment is the binding constraint:
  unguarded parameters and struct patterns infer `term()` fields, so most
  real clauses escape the spec domain. Gating recall on known real
  omissions is 0 of 9.
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

1. **Body analysis backend** (DESIGN section 7). Qualify the
   `Module.Types.warnings/7` hook on a pinned build. Check one slice at a
   time with the full tuple domain, in fresh checker context, in
   dynamic-domain mode. Diff ordinary diagnostics against spec-domain
   ones. Measure per-slice cost on `Enum` and `Keyword`, and validate
   local-call caching, recursion and widening. This is the path to
   resolving `possible_domain_escape` and `possible_input_approximate`,
   and to SL007.
2. **Upstream API request.** Ask for "infer this definition under these
   argument domains", returning diagnostics, a signature and a capability
   version. In the same request, ask to export the compiler's per-clause
   redundancy verdict, which would replace the shadowing approximation.
   Also ask for a stable, documented reader for the `ExCk` chunk.
3. **SARIF output** next to the console and JSON reporters. Map rule IDs,
   evidence and fingerprints (as `partialFingerprints`) and the baseline
   state (as `baselineState`).
4. **Caching under `_build`.** Key per-module results on the BEAM md5, the
   adapter ID and the config digest. Reuse remote type expansion across
   runs, and keep invalidation deterministic so JSON stays byte
   identical.
5. **Additional adapters.** Add one module per qualified compiler revision
   (the next 1.21 development tips, then 1.21.0). Each needs the
   differential tests for `apply_infer/2` and a published support matrix.
   Run the stdlib regression per revision.
6. Stdlib dogfooding: migrate the prototype's 68-entry exclusion list to a
   fingerprinted baseline.
7. Re-run the SL002 experiment whenever the classifier or containment
   changes (DESIGN section 12). The struct-field containment question is
   the most promising lever for recall.
