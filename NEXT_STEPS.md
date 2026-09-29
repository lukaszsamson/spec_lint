# Current next steps after Phase 4

Phase 4 delivery and validation are recorded in `PHASE_4_PLAN.md` and
`STATUS.md`. Earlier plans below are historical.

1. Qualify the minimal compiler counterexamples on an isolated, unmodified
   upstream revision before proposing changes upstream. Keep precision
   limitations separate from demonstrated compiler soundness bugs.
2. Extend the isolated helper experiment to a normal-return summary for a
   helper that either returns an argument or raises. Freeze positive and
   negative controls first: multiple callers, side effects, exceptions,
   overloads, guards, recursion and code-size limits. Require a witnessed
   real omission to improve before adopting a compiler change.
3. Ask for source-to-stored clause mappings and reachability information in
   the checker API. Local guard witnesses reduce false gates but do not prove
   normal return or establish that mapping. Do not infer a precise mapping
   from clause indices.
4. Treat Absinthe as a performance regression benchmark. Milestone 1
   removed type printing from classification, and its review moved
   rendering out of the run process: `Run.execute/3` takes 60.6-66.8 s
   without rules and 62.5-64.4 s with the default rules, so the 60-second
   target is not met, and the full product run 73-75 s
   (`bench/corpus/reports/m1_review/`). The remaining cost is translation
   and garbage collection of about 3.3 GB of retained translated bounds.
   Sharing translated named types across slices is the next lever. Preserve
   conservative lower/upper bounds and loss records if expansion is capped
   or memoised (loss paths are relative to the slice).
5. Keep valid spec contradictions eligible regardless of `@doc false` or
   constructor naming. Use explicit baselines for accepted debt; documentation
   visibility does not change the declared contract. Keep new corpora for a
   frozen holdout once there is a precision change to test.

# Next delivery: evidence quality and broader validation

Started 2026-09-29 from `caff376`. This is the execution plan; completion and
results will be recorded here and in STATUS.md.

1. Harden report reduction, provenance and incomplete-run handling. Separate
   body-analysis candidates from actual gates. Fix the two remaining build
   integrity cases found in review.
2. Add executable counterexample assertions for all nine omission fixtures,
   independent of the translator/classifier.
3. Freeze a broader OSS cohort before changing inference or classifier logic:
   Req, Broadway, Oban, Phoenix LiveView, Ash and Nx. Treat Ash and Nx as
   holdouts for any precision prototype. Compile isolated copies with pinned
   revisions; preserve failures as evidence, not zero-finding successes.
4. Run signature analysis and consumer integration where feasible; retain
   reports and provenance. Review gated findings and a deterministic sample
   of candidates and unknowns. Distinguish corpus observations from measured
   recall on known counterexamples.
5. Select a narrowly justified precision experiment from observed blockers.
   Do not adopt a production change without negative controls and measurable
   benefit. Empty lower bounds caused by unrepresentable required integer
   refinements cannot be repaired by unsound widening.
6. Run an independent adversarial review, address findings, then run tests,
   full Credo, formatting, Dialyzer and the self-check on the final tree.

No broad compiler rewrite, SARIF or persistent caching is part of this
delivery. Existing CI evidence policy remains unchanged unless experiments
justify a documented change.

## Delivered

All six steps above are complete. The expanded corpus adds 1,252 functions
and 1,260 slices, all supported; 1,037 obligations remain unknown. One gate
(`Oban.Registry.via/3`) is a witnessed true omission. Three nongating Ash
reports have independent runtime witnesses; the other Ash judgments are
separated into source-supported, probable, unconfirmed and refuted in
`bench/corpus/holdout_triage.md`. Req's broad constructor counterexample is
unreported. A real Req path-dependency consumer passed the Mix task.

Four build-integrity cases were corrected: invalid-manifest fallback,
missing owned-app inventory, corrupt BEAMs, and filename/module mismatches.
The benchmark now preserves complete large reports, pins sources, records
content provenance, and distinguishes incomplete runs from clean scans.
Body metrics no longer merge candidates into gated recall or count missing
analysis as a miss. Nine stand-in fixtures have executable assertions.
The 33-clause precision experiment ruled out a lower-bound-only containment
fix for those existing stored signatures. No production classifier change
or body backend was adopted.

Independent Sol reviews found and resolved metric unavailability handling,
stale body-build reuse, incomplete provenance, and further artifact-integrity
holes. The final test suite passed 281 tests; the last test-only alias cleanup
was followed by all 13 coverage tests. Full default Credo (70 checks), format,
Dialyzer (zero errors), and `mix spec_lint --ci` on itself all pass. The self
check compared 272 slices and exited 0. Canonical-path normalization also has
a regression test. Reports are in `bench/corpus/reports/expansion/`.

## Next experiment, not silently adopted (delivered 2026-09-29)

1. Investigate clause-local translation-loss qualification using the witnessed
   `Ash.Page.page_opts/1` omission. Establish the bound/polarity proof and keep
   negative fixtures for arrows, overlapping overloads and impossible inputs.
2. Add controlled valid-resource integration witnesses for the source-only Ash
   reports, particularly `return_query?` paths, before treating them as runtime
   ground truth. Keep broad-domain constructors separate from ordinary inputs.
3. Freeze a new holdout before changing policy; Ash/Nx are now observed. Measure
   incremental gates and false positives against this committed baseline.
4. Continue compiler discussions with minimal counterexamples for helper call
   sensitivity and higher-order collection results. Retain the current decision
   against a production body backend until recall improves measurably.

### Delivered

All four items are done and committed (`10970dc`, `1126a5b` and the Close
phase commits that follow them).

- **Item 1: adopted as the default.** `clause_local_qualification: true`,
  gating in both profiles (`bench/corpus/clause_local_qualification.md`,
  "Decision"). On 15 real-code corpora (4,204 compared slices) it adds
  one gate, `Ash.Page.page_opts/1`, a witnessed true positive, and no false
  positive. An independent adversarial review found that `clause_reachable`
  missed clauses whose guard contradicts their pattern. That is fixed for
  both settings: the compiler's own pattern and guard check is re-run over
  debug info (`SpecLint.Reachability`). All twelve review findings are
  resolved.
- **Item 2: done, then corrected by the review.** Five source-only Ash
  reports are witnessed with inputs checked against their declared types.
  `Query.apply_to/3` is probable, because its escape was only observed
  outside `Ash.Query.t()`, and `data_layer_query/2` is refuted
  (`holdout_triage.md`, `reports/expansion/ash_integration_witnesses.json`).
- **Item 3: done.** absinthe and tesla were frozen at `3b89842`
  (`holdout2_baseline.md`, `expansion.json`) before the experiment ran.
  They had no arrow-blocked clause conflict, so they agree with the tuned
  corpora but cannot show a benefit.
- **Item 4: counterexamples written.**
  `bench/corpus/compiler_counterexamples/` holds minimal modules for helper
  insensitivity and `Enum.map/2` results, with a self-checking script
  (`check.exs`) and a README. They have not been sent upstream yet. The
  decision against a production body backend stands.

## Next experiments, not silently adopted

1. **Upstream discussion.** Take `compiler_counterexamples/` to the
   compiler maintainers. Also ask for two checker-chunk additions: a
   per-source-clause reachability verdict, and the mapping from source
   clauses to stored clauses. The mapping would let `clause_reachable` block
   per clause instead of per function, and let findings name their source
   clause and line.
2. **Source clause mapping without upstream.** Prototype recomputing the
   checker's clause grouping from debug info on a qualified compiler
   revision, and measure whether it maps every stored clause back to its
   source clauses on the fixtures and the corpora. Adopt it only if it is
   exact on all of them; otherwise keep the stored-clause labelling.
3. **A holdout with power for the qualification.** Choose a third holdout
   by a criterion fixed in advance: projects whose baseline run has clause
   conflicts blocked by an arrow prerequisite with the qualification off.
   Freeze it, then measure new gates and false positives with the default.
   The two current holdouts could not test it.
4. **Dead clauses the type checker cannot see.** Build fixtures with
   contradictory numeric guards and with clauses only the Erlang compiler
   reports, and count how often they occur in the corpora. If they occur in
   real code, consider requiring a static guard-free clause for
   `clause_reachable: met`.
5. **Default-`nil` struct fields.** The seven absinthe gates on
   `Absinthe.Blueprint.Input.parse/1` are real violations of the declared
   struct types, but they are a usability question for CI (like Req's
   `Response.new/1`). Measure how many gates on all corpora come from
   default-`nil` fields before deciding whether they need their own
   evidence class. Do not change the policy without that data.
6. **Silent false negatives and open witnesses found by the review.**
   `Ash.Page.page_opts/1`'s catch-all returns `{:ok, keyword}`, never a
   page, but SpecLint is silent because the stored payload is gradual
   (`mod.to_options/1` on a variable module). Record it as a known miss
   next to the nine. Search for an in-domain error path of
   `Ash.Query.apply_to/3`, or record that there is none.
