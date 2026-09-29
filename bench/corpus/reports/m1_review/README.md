# Milestone 1 review replay

The fifteen pinned corpora rerun after the fixes to the Milestone 1 review
findings (`STATUS.md`, "Milestone 1 review"), compared with `../m1/`. These
are regression corpora, not fresh holdouts. Regenerate as in
`../m1/README.md` with `SPEC_LINT_CORPUS_OUT` set to this directory, then
`(cd bench/corpus/reports && ../compare_replay.sh m1_review m1)`; the
comparison, with notes and timings added, is `summary.json`. The tool
source digest in the provenance files was taken before these reports and
this README were added.

## What changed

- Rendering: `SpecLint.Report.render/2` renders the JSON and console
  reports in a short-lived process that receives the run without its
  analysis results, and `SpecLint.Run.execute/3` loads SpecLint's modules
  and the standard library modules its later stages use before the
  analysis. No report content changes.
- Union member order: the translation unites a union's members in Erlang
  term order. The compiler fuses two tuple or map literals that differ in
  one position when it unites them, so the order decided the
  representation, and the fingerprint, of the same set.
- Shadowed required map keys: a required literal key after a domain that
  covers it (`%{optional(any()) => any(), year: integer()}`, the
  `Calendar.date()` form) records `map_key_widened`. The lower bound now
  requires the key; before, Dialyzer's reading was called exact, and its
  lower bound admitted maps without the key.

## Results

All fifteen runs are complete, with the same exit codes, 4,204 compared
slices, 63 findings and the same 9 gates as `../m1/`. Eleven reports are
byte-identical to `../m1/`. The other four differ as follows; no evidence
class, gate or exit code changed.

| Corpus | Ledger | Fingerprints changed | Cause |
| --- | --- | --- | --- |
| stdlib | `map_key_widened` 56 → 128 | `Date.diff/2`, `DateTime.to_unix/2`, `Time.diff/3` | calendar map types (shadowed required keys); `Date.diff/2` also gains the reason `{:containment_unknown, [0, 1]}` |
| ecto | 5 slices exact → approximate; `map_key_widened` 101 → 109 | `Ecto.Changeset.field_missing?/2`, `Ecto.Query.Builder.quoted_type/2` | shadowed required keys; union order |
| ash | unchanged | `Ash.load/3` | union order (the slice prints the same members in another order) |
| absinthe | `map_key_widened` 378 → 379 | all seven `Absinthe.Blueprint.Input.parse/1` gates, `Absinthe.Phase.Init.run/2` | shadowed required keys; union order for `Init.run/2` |

**Baseline migration.** 13 of the 63 findings changed fingerprint,
including the seven gated Absinthe findings. A baseline that acknowledges
an affected finding no longer matches it, so the finding counts as new and
the old entry as stale: regenerate such baselines with
`mix spec_lint.baseline` after reviewing them. The baseline format version
is unchanged.

## Absinthe timing

Same machine, one run at a time, `bench/absinthe_profile.exs` (which now
renders through `SpecLint.Report.render/2`, as the Mix task does):

| Measurement | Milestone 1 (`e4fc0c7`) | After the review fixes |
| --- | --- | --- |
| `Run.execute/3`, no rules | 59.3 s (one run); 61.7 s re-measured by the review | 60.6-66.8 s in five runs, median 62.9 s |
| `Run.execute/3`, default rules | 64.8-68.2 s; 63.2 and 64.6 s re-measured by the review | 62.5 and 64.4 s |
| JSON render, default rules (27 types printed) | 1 s to 78 s | 0.13 and 0.17 s |
| JSON render, no rules (nothing printed) | 7.3 s (review) | 0.01-3.8 s: at most one garbage collection of the run process |
| Product end to end (`run_on_ebin.exs --ci --format json`) | 109 s | 73 and 75 s |

The 60-second target for `Run.execute/3` is not met, with or without
rules: the single 59.3 s sample of Milestone 1 was at the low end of a
60-67 s spread.
