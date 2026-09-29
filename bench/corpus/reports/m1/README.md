# Milestone 1 replay: no type printing during classification

Repeated measurements of the fifteen pinned corpora after Milestone 1
(`STATUS.md`, "Milestone 1"). These are regression corpora, not fresh
holdouts. Each report has source, BEAM, compiler and tool-source provenance
beside it.

## What changed

- `SpecLint.Evidence` classifies on `Descr` terms only. A component keeps
  its `descr`; the printed `descr_string` is gone. `SpecLint.Compare` never
  printed.
- Rules keep their details unrendered (`SpecLint.Issue.text/0`); the JSON
  and console reporters render them with `Issue.rendered_details/1`, for the
  findings they show. `SpecLint.Run.execute/3` prints no type.
- The adapter printer (`SpecLint.Compiler.V121.to_string/1`) memoises tuple
  and map literals within one call and prints the complement form against a
  length budget. It returns the same string as before for every type.
- Two garbage-collection costs of the run process were removed: BEAM hashes
  are read before the analysis, and each reachability check runs in its own
  process.
- Fingerprints: `SpecLint.Compiler.canonical/1` was already structural (a
  sorted-term serialisation of the `Descr` term, no printing). It is
  unchanged, so fingerprints and the baseline format version (1) are
  unchanged and no migration is needed. *The later review fixes (union
  member order, shadowed required map keys) did change 13 of these 63
  fingerprints; see `../m1_review/`.*

## Regenerate

From the repository root, with the checkouts of `bench/corpus/README.md`
and `bench/corpus/expansion.json`:

```sh
SPEC_LINT_PRODUCT_ONLY=1 SPEC_LINT_OSS="$ORIGINAL_OSS" \
  SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/m1" \
  bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_PRODUCT_ONLY=1 SPEC_LINT_OSS="$EXPANSION_OSS" \
  SPEC_LINT_CORPUS_MANIFEST="$PWD/bench/corpus/expansion.json" \
  SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/m1" \
  bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
(cd bench/corpus/reports && \
  ../compare_replay.sh m1 phase4 expansion/clause_local/on:absinthe)
```

The runs used `ASDF_ELIXIR_VERSION=path:$HOME/elixir` and
`ASDF_ERLANG_VERSION=28.5.0.1` (Tesla's `.tool-versions` names 1.19). The
runs were made one corpus at a time. `summary.json` is the output of
`compare_replay.sh` plus the timing and migration notes.
The comparison script was added to `bench/` after the replay, so the tool
source digest in the provenance files
(`ba815878...35e7d5`, the same for all fifteen) does not include it.

## Results

All fifteen runs are complete, with the same exit codes as their baselines
(Ash, Oban and Absinthe exit 1 on gates; the rest exit 0).

| Corpus | Baseline | Slices | Findings | Gates before → after | Fingerprints |
| --- | --- | --- | --- | --- | --- |
| stdlib | phase4 | 1,777 | 33 | 0 → 0 | unchanged |
| jason | phase4 | 20 | 0 | 0 → 0 | unchanged |
| decimal | phase4 | 46 | 2 | 0 → 0 | unchanged |
| nimble_options | phase4 | 5 | 0 | 0 → 0 | unchanged |
| mime | phase4 | 5 | 0 | 0 → 0 | unchanged |
| plug | phase4 | 86 | 0 | 0 → 0 | unchanged |
| ecto | phase4 | 165 | 4 | 0 → 0 | unchanged |
| req | phase4 | 87 | 0 | 0 → 0 | unchanged |
| broadway | phase4 | 30 | 0 | 0 → 0 | unchanged |
| oban | phase4 | 130 | 2 | 1 → 1 | unchanged |
| phoenix_live_view | phase4 | 12 | 0 | 0 → 0 | unchanged |
| ash | phase4 | 992 | 12 | 1 → 1 | unchanged |
| nx | phase4 | 9 | 0 | 0 → 0 | unchanged |
| absinthe | expansion/clause_local/on | 453 | 9 | 7 → 7 | unchanged |
| tesla | phase4 | 387 | 1 | 0 → 0 | unchanged |

Totals: 4,204 compared slices, 63 findings, 9 gates before and after.

- The fourteen reports with a Phase 4 counterpart are **byte-identical** to
  it: ledger, inventory, findings with their rendered details,
  fingerprints, gate decisions and configuration.
- Absinthe has no complete Phase 4 report. Against the Phase 3 flag-on
  report its ledger, gates, fingerprints and exit code are identical. The
  findings differ only in the detail label of the seven clause conflicts,
  `inferred clause` → `stored signature clause`, adopted before Phase 4
  (`PHASE_4_PLAN.md`); with details removed the findings are identical. Its
  seven `Absinthe.Blueprint.Input.parse/1` findings are also identical,
  details included, to the scoped Phase 4 report
  `../phase4/absinthe.input.spec_lint.json`. This is the first complete
  Absinthe replay since Phase 3.
- The experiment reports (`bench/experiment.exs`, which prints every
  component) for fixtures, jason, ecto and plug are byte-identical to
  `../`; stdlib differs only in the reduction note of the historical
  reduced file. They are not part of this directory.

## Absinthe timing

`bench/absinthe_profile.exs` on the pinned Absinthe build (468 BEAMs, 12
cores, one run at a time):

| Measurement | Before (`39f3924`) | After |
| --- | --- | --- |
| `Run.execute/3`, no rules (`only: []`, what the Phase 4 profile measured) | 576 s, 684 s (Phase 4 profile); 606 s re-measured | 59.3 s |
| `Run.execute/3`, default rules (`mix spec_lint --ci`) | not measured (Phase 4 full replay stopped after about 15 min) | 64.8 s and 68.2 s |
| Types printed by `Run.execute/3` | every component of every slice, twice | 0 |
| Product end to end (`bench/run_on_ebin.exs --ci --format json`) | 345 s in Phase 3; no complete Phase 4 run | 109 s |
| Corpus runner wall time (includes provenance hashing) | no complete Phase 4 run | 118 s |

The 60-second target is met only without rules (59.3 s). With the default
rules `Run.execute/3` takes 65-68 s. *The review re-measured 61.7 s without
rules; five later runs took 60.6-66.8 s (`../m1_review/`), so the target is
not met in either mode.* What remains was measured separately:

- Translation and comparison compute: about 31 s when each module's result
  is discarded.
- Garbage collection of the run process: it retains about 3.3 GB of
  analysis results, almost all translated spec bounds (Absinthe's Blueprint
  struct types are expanded per spec, without sharing between slices).
  Retaining the results makes the same analysis take 55 s; before this
  milestone the same effect made reading BEAM hashes after the analysis take
  44-120 s (0.1 s in a fresh process), and the reachability checks took
  12-37 s in the run process in two measurements. Their time in their own
  processes was not isolated.
- Rendering the nine findings prints 27 types (46 `Descr` prints) and takes
  76 ms in a fresh process, but the JSON rendering in the run process took
  between 1 s and 78 s in separate runs. That variance was not investigated
  further; it accounts for most of the difference between `Run.execute/3`
  and the end-to-end time. *Later explained (`../m1_review/`): printing a
  map type loads the module of each struct it prints, and every code load
  in the run process took seconds, depending on how many were still to
  load. Rendering now happens in a short-lived process: 0.13-0.17 s, and
  73-75 s end to end.*

A lower memory translation (sharing translated named types across slices)
is the next performance lever; it is not part of this milestone.
