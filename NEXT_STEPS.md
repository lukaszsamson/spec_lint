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

## Next experiment, not silently adopted

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

Source changes and results are left uncommitted for review. The pre-existing
`PHASE_2_REVIEW.txt` was not modified.
