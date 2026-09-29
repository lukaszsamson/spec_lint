# Phase 4: trustworthy gating and a bounded precision experiment

Started 2026-09-29 against the Phase 3 implementation (`0cc9c50`);
the working branch also contains the upstream-findings documentation commit
`5f43764`. Preserve the Phase 3 reports and review.

1. Replace diagnostic absence as the sole guard safety signal with conservative
   guard-feasibility qualification. Cover direct and macro compound guards,
   alternatives and unsupported expressions; preserve known
   positive cases when evidence justifies them.
2. Make a failed required reachability check incomplete analysis (CI exit 2)
   regardless of the clause-local switch or baseline. Skip checks when SL001
   is disabled; failures on findings blocked for other reasons are not required.
3. Investigate bounded helper inference with independent controls, isolated
   experimental files, and explicit separation of synthetic precision gains
   from new real-code detections. Do not change the qualified compiler adapter
   to accommodate an unqualified compiler.
4. Independently review the implementations adversarially; resolve findings
   and retain regression probes.
5. Rerun the 15 existing corpora with pinned artifacts and provenance. Report
   lost as well as retained gates; these are regression corpora, not fresh
   holdouts. Retain prior reports for comparison.
6. Run tests, full Credo, formatting, Dialyzer and self CI check. Update design,
   status and experiment docs with actual results and remaining limits.

Sol agents own guard qualification, incomplete-run handling and the helper
experiment respectively. The root integrates, checks cross-cutting behavior,
reviews and runs corpus validation. Changes remain uncommitted for review.

## Implementation and review

Both review findings are fixed: compound impossible guards no longer qualify
SL001 gates; a failed required compiler recheck makes CI exit 2 even under the
legacy qualification switch or an existing baseline. The guard interpreter
uses concrete witnesses, complete supported heads, OR semantics for alternate
`when` guards, and exclusion by preceding source clauses. Candidate Cartesian
products are capped at 4,096 at each step. Unsupported syntax and unsuccessful
search are conservative unknowns. Variable-module struct heads are supported
with atom-tag checks, binding consistency and field matching.

Adversarial review corrected four classes of mistakes before delivery:

- Alternate `when` guards were initially treated as conjunctions. Current and
  preceding clauses now use their actual alternative semantics.
- Candidate products needed truncation during construction, not after an
  unbounded expansion. Wide-head controls retain the bound.
- Prior clauses and repeated variable bindings must participate in witness
  checking, including clauses that always raise and disappear from signatures.
  Unsupported prior patterns cannot count as proof of nonmatching.
- The experimental transform initially overlooked guarded overloads, confused
  a call AST with a variable, and visited quotes/captures. Frozen adversarial
  controls now cover these cases; the prototype remains deliberately narrow.

Independent review of the final dynamic struct matcher used compiler-produced
ASTs and runtime matching, including repeated module bindings and interception
by prior clauses. No further concrete defect was found. This does not prove
source-to-stored clause correspondence or normal return. Those limits remain
explicit in DESIGN and the implementation.

## Validation

Final production source: 322 tests pass; full strict Credo (70 checks) reports
no issues; format check passes; Dialyzer reports zero errors. The self CI check
compares 277 specs with no findings and exits 0. The four helper/counterexample
scripts in `bench/helper_experiment/REPORT.md` also pass. Changes remain
uncommitted for review.

The helper prototype matches inline signatures in four synthetic pairs. It
adds **zero independently confirmed real-library detections** and does not
recover the motivating raising-helper example. No body backend, compiler
patch or new gating rule was adopted.

## Corpus result and remaining performance limit

Fourteen whole-project replays completed: 3,751 compared slices, 2,739 unknown
obligations and 54 findings. Every ledger and every gate decision matches the
Phase 3 flag-on reports. Both existing gates (Ash and Oban) remain; none were
added or removed. The only display difference is the already adopted Phase 3
label “stored signature clause”. No existing finding becomes guard-unproven.
The reports and machine-readable comparison are in
`bench/corpus/reports/phase4/`.

Absinthe's full replay did **not** complete within this experiment's budget.
It was manually stopped after approximately 15 minutes; the runner exited 2
because it had no complete report. This is not a product-produced exit-2
verdict or a clean scan. A preliminary run was also interrupted. Source,
compiled artifacts and compiler hashes match the prior report, whose separate
full product measurement was 345 seconds. Samples of the preliminary attempt
showed translation, Descr construction and printing; the guard qualification
itself took under a millisecond on `parse/1`. These observations do not isolate
a regression, and no throughput improvement is claimed.

A separate **partial** run of `Absinthe.Blueprint.Input` completed and retains
all seven known gate fingerprints, exiting 1. Thus all nine previously
witnessed gates are validated across the complete and scoped runs, but this
is not a completed 15-project replay. Full Absinthe coverage remains unverified
on this tree. Preserve that distinction in future release claims. Prioritize
an isolated before/after profile of translation and reporting, with explicit
resource budgets, before declaring whole-project CI performance qualified.
