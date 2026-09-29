# Milestones (plan of 2026-09-29)

The six milestones below replace the numbered lists further down, which are
kept as history. Performance, compiler compatibility and evidence policy
stay in separate changes. Exit criteria are copied from the plan.

## M1. Remove printing from analysis on the existing compiler: done, one criterion not met

*Done when:* Absinthe completes under 60 seconds under recorded
conditions; all fifteen corpora preserve coverage, classifications, gate
decisions and existing fingerprints; quality gates pass; independent review
checks that rendering no longer affects classification.

Delivered in `e4fc0c7` and the review fixes `63618c2` (STATUS.md,
"Milestone 1" and "Milestone 1 review"). Classification works on `Descr`
terms and prints nothing; rendering runs in a separate process. Absinthe:
`Run.execute/3` went from 576-684 s to 60.6-66.8 s without rules (median
62.9 s) and 62.5-64.4 s with the default rules; the product run from 345 s
(Phase 3) to 73-75 s. **The 60-second target is not met** (the remaining
cost is translation and garbage collection of about 3.3 GB of retained
bounds; sharing translated named types across slices is the next lever).
Coverage, classifications and gates are preserved on all fifteen corpora.
Fingerprints were preserved by Milestone 1 itself; the review's two
correctness fixes (union member order, shadowed map keys) changed 13, with
the migration documented (regenerate baselines). The independent review
checked that rendering no longer affects classification, and tests pin it
(a stub adapter that cannot print gives identical classifications and runs).

## M2. Qualify upstream 1.21 at `648b2a9`: done

*Done when:* a clean CI machine can reproduce the build and qualification
without your fork. Record every difference from `c24c235`; identical
results are an expectation to test, not a prerequisite to force.

Delivered in `41f56c3` and the Milestone 2 review (STATUS.md). A fresh
clone builds and qualifies without the fork; the audit
(`bench/corpus/toolchain/audit-648b2a9.md`, 25 rows) records every
difference, including the `for ... into:` soundness defect of 648b2a9 (row
19). The review closed the remaining reproducibility gaps: a corrupt BEAM
under a deep checkout path, provenance that named the wrong tool revision
or path-dependent hashes, missing repository URLs, and two high findings
(artifacts of the other build analysed under the running adapter; a
modified build of a qualified SHA passing preflight).

## M3. Add and qualify the 1.20 adapter: done

Keep descriptor construction, inspection and application differences inside
the adapter. Run the same behavioral tests, then rebuild the corpus using
1.20 and produce separate reports and baselines.

*Done when:* both compiler versions pass their own qualification,
cross-version artifacts fail closed, and omission classifications are
pinned per adapter. Adapter selection must consider the running compiler
and artifact compatibility, not the artifact's chunk alone.

Defer 1.19 until measurements show enough useful coverage to justify
maintaining it. Do not advertise it as supported yet.

Delivered (STATUS.md, "Milestone 3"): `SpecLint.Compiler.V120` qualified
for Elixir 1.20.4 (`759443e`, audit `bench/corpus/toolchain/audit-1.20.4.md`,
35 rows) next to `V121`; the adapter is selected from the running
compiler's version and chunk version, and the build record names the
compiler line, so the other line's artifacts are refused (exit 2) with or
without a record. The suite passes under c24c235, 648b2a9 and 1.20.4, with
line-dependent expectations pinned per adapter. The fifteen corpora compile
and replay under 1.20.4 (`bench/corpus/reports/elixir-1.20.4/`) with the
same coverage, gates and exit codes as 1.21 outside the standard library;
fingerprints differ, so baselines are per adapter. 1.19 is not supported.

The Milestone 3 review (STATUS.md) found one high defect, fixed: a forced
recompile after `compile` already ran in the VM (`mix do compile +
spec_lint`, an alias, the self-check) was a no-op, and the other build's
BEAM files were recorded as the running build's. The Mix tasks now
re-enable the compile chain and fail closed (exit 2) when the forced
compile still does nothing; dependencies compiled by another compiler line
are refused (exit 2). Two 1.20.4 presentation and classification
differences in `DescrWalk` were fixed or pinned.

## M4. Investigate source-clause mapping: done, structural classes adopted

Start with a diagnostic experiment, separately from production gating.
Exercise merged clauses, omitted raising clauses, guards, defaults, macros
and generated definitions. Identify compiler invariants that justify the
mapping; agreement across the corpus alone does not prove exactness.

*Done when:* supported mappings are justified and tested, and ambiguous
cases retain conservative function-wide blocking. Mapping and guard
feasibility still do not establish normal return. This milestone should not
block an explicitly documented experimental release if it proves
impractical.

Delivered (STATUS.md, "Milestone 4"; `bench/clause_mapping/README.md`, the
report). Adopted: the two classes the compiler's grouping invariants force
without any type, a function with one source clause and a function with as
many stored as source clauses (`SpecLint.ClauseMapping`, checked in the
source of all three qualified builds and tested under both lines). They
cover 93.5% of the 21,439 functions with an inferred signature on the
fifteen corpora, with no disagreement from the compiler replay on the
19,825 it could check, and all nine corpus clause conflicts. They only name
the source clause and line in a clause conflict's details and data; gates,
prerequisites and fingerprints are unchanged, and `clause_reachable`
blocking stays function-wide for every function (diagnostic lines are not
attributed to clauses; no corpus conflict is blocked by one). Not adopted:
every typed mapping (recomputed head types), which is not exact (the
checker's `subpatterns` leak, protocol implementations, gradual bounds
widened by subtraction, the redundant-clause path) and gives wrong exact
claims on warning-free fixtures.

## M5. Freeze the evaluation and run the release campaign: next

**First task: the frozen evaluation inventory.** Before any M5
measurement, commit one inventory file that freezes the executable
witnesses, the omission-family identities, the recall denominator and the
holdout-selection procedure, with the audit of the proposed "six witnessed
Ash misses" against the witness records. Every later M5 number is computed
against that commit; changing it is a new, documented freeze.

Freeze executable witnesses, omission-family identities, the recall
denominator and holdout-selection procedure now. Audit the proposed "six
witnessed Ash misses" against the witness records before counting them.
Do not count the seven Absinthe gates as seven independent omission
families.

During qualification, count struct-default violations separately without
changing their policy. Re-run all known gates and independently attempt to
refute every new or changed gate.

*Done when:* both supported adapters meet correctness and runtime budgets,
installation and upgrade workflows pass, and the README publishes the
support matrix, unknown-obligation counts and gating limitations.

For resource failures, require **no successful result**. Caught analysis
failures can exit 2; an externally killed or OOM-terminated VM cannot
reliably promise that exact exit code.

Progress (2026-09-29): the frozen inventory (`e464905`) and release
campaign 1 (`bench/corpus/reports/release-1/`, tool `06b7496`) are done:
qualification under the three compilers, the fifteen-corpus replay with
provenance, runtime and memory budgets (`bench/corpus/budgets.json`,
checked by `run.sh`), the resource-failure tests, struct-default counts and
the gate list for refutation (`release-1/gates.json`, 27 gates, none new).
Remaining: independent refutation of the listed gates, installation and
upgrade workflows, and the README support matrix with unknown-obligation
counts and gating limitations.

## M6. Move inference work upstream (submission preparation): after M5

Stop extending the local helper source transform. Prepare the helper and
collection counterexamples, recheck the `list_tl` finding on upstream, and
include the printer profile. Submission is a separate authorized action.

Resume local inference experiments only around an upstream mechanism that
can be qualified against the frozen evaluation. The `for ... into:`
narrowing of 648b2a9 (`UPSTREAM_BUGS.txt` item 11, audit row 19) belongs in
the same package, and so do the Milestone 4 findings for the checker API:
the `subpatterns` leak between definitions
(`bench/clause_mapping/subpatterns_leak.ex`) and the request for a
per-source-clause mapping and reachability verdict in the checker chunk,
which the structural classes cannot replace for merged or dropped clauses.

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
   exact on all of them; otherwise keep the stored-clause labelling. (Done
   as Milestone 4: only the structural classes are exact by construction
   and were adopted; the typed recomputation is not exact.)
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
