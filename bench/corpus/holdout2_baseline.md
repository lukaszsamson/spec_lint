# Second holdout: pre-change baseline

Frozen at tool commit `3b89842` (`3b89842c03eba488a97c06cd5922d0ae3e374eb5`),
2026-09-29, before any classifier or inference change. This is a baseline,
not a triage: nothing below was judged against source, and no finding is
called true or false. Ash, Nx, Req, Broadway, Oban and Phoenix LiveView are
already observed and are not part of this holdout. Use these two projects
only to measure the incremental effect of later changes; do not tune against
them and then reuse them as a holdout.

Candidates were tried in the order absinthe, tesla, finch, bandit. The first
two compiled on the pinned toolchain, so finch and bandit were not attempted
and there are no compile failures to record.

## Revisions and build

| Project | Revision | Commit date | Manifest entry |
| --- | --- | --- | --- |
| absinthe | `1372ceb5f8226175050a38821601cd57738c177b` (release 1.12.0) | 2026-09-02 | `holdout: true`, `frozen_at: "3b89842"` |
| tesla | `f1d040b237cf6fe07fc57d4915d95dca24546483` | 2026-09-28 | `holdout: true`, `frozen_at: "3b89842"` |

Both are `git clone` at upstream HEAD into `/tmp/spec-lint-expansion/<name>`,
worktrees clean before and after (`git status` empty; `mix.lock` is committed,
so `deps.get` changed nothing). Both were built in place with
`MIX_ENV=test mix deps.get && MIX_ENV=test mix compile` under Elixir
1.21.0-dev (`c24c235`), OTP 28. The dependency compile logs are in
`/tmp/spec-lint-expansion/logs/{absinthe,tesla}.build.log`
(`tesla.deps.log` for its `deps.get`).

Toolchain caveat for Tesla: its `.tool-versions` selects `elixir 1.19-otp-28`
and `erlang 28.5`, which the asdf shims would honour. The build and all
analysis were run with `ASDF_ELIXIR_VERSION=path:/Users/lukaszsamson/elixir`
and `ASDF_ERLANG_VERSION=28.5.0.1`, and `mix --version` confirmed
`Mix 1.21.0-dev (c24c235)`. The `.tool-versions` file itself was not edited.
Absinthe has no `.tool-versions`. Tesla's compile printed compiler warnings
(22 lines matching "warning"); Absinthe's printed one. Neither failed.

Reports (all in `bench/corpus/reports/expansion/`):

- `NAME.json` and `NAME.json.gz`: the SL002 experiment report. For both
  projects the full normalised JSON is in `.json.gz` and `.json` is the
  schema-checked summary (`run.sh` behaviour for large reports).
- `NAME.spec_lint.json`: the `--ci` product report.
- `NAME.provenance.json`.

Regenerate with the invocation documented in `bench/corpus/README.md`:

    SPEC_LINT_OSS=/tmp/spec-lint-expansion \
    SPEC_LINT_CORPUS_MANIFEST="$PWD/bench/corpus/expansion.json" \
    SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/expansion" \
    bench/corpus/run.sh absinthe tesla

Provenance notes. The tool revision in both files is `3b89842` with
`dirty: true` because `expansion.json` was edited and not committed, and
because other uncommitted files existed in the tree. Tool source digests:
absinthe `21f2c7cc...e08f4` (identical to the Nx digest, so `lib/`, `bench/`
scripts and `mix.exs` match the earlier expansion runs); tesla `6acbaf56...96f0`.
The tesla digest differs only because `provenance.sh` hashes any file matching
`bench/*.exs`, and the shell `case` glob `*` also matches `/`, so an untracked
`bench/corpus/ash_integration_witnesses.exs` (created in the working tree by
another task while the absinthe run was in progress) entered that digest.
Recomputing the digest without that one file gives the absinthe/Nx value
exactly. This is a provenance-script imprecision, not a change to analysis code.
Absinthe compiled artifacts: 468 BEAM files in `absinthe/ebin`; Tesla: 100.
Absinthe `mix.lock` sha256 `fe6c4dc1...cdd6`, Tesla `cc7af3d5...5cf`.

## Coverage

Both product runs are `complete`: no coverage violations, zero unavailable
and zero unsupported functions or slices.

| | absinthe | tesla |
| --- | --- | --- |
| Modules discovered / analysed | 468 / 467 (1 out of scope: `absinthe_parser`, an Erlang module) | 100 / 100 |
| Functions found / compared | 451 / 451 | 313 / 313 |
| Slices found / compared | 453 / 453 | 387 / 387 |
| Slices exact / approximate | 58 / 395 | 34 / 353 |
| Specs out of scope | generated 48, not exported 99, protocol 3, macro 2 | generated 4, not exported 11 |
| Signatures available | 451 | 313 |
| Product exit code | 1 (7 blocking findings) | 0 |

Approximation loss kinds across slices (a slice can carry several):

| Loss kind | absinthe | tesla |
| --- | --- | --- |
| `integer_refinement_erased` | 390 | 2 |
| `recursive_cutoff` | 378 | 336 |
| `map_key_widened` | 378 | 166 |
| `arrow_polarity` | 368 | 332 |
| `opaque_boundary` | 2 | 348 |
| `type_variable_correlation` | 5 | 1 |

Obligations (per compared slice):

| Obligation | absinthe | tesla |
| --- | --- | --- |
| established | 70 | 12 |
| compatible_after_approximation | 6 | 1 |
| possible_mismatch | 3 | 1 |
| unknown | 374 | 373 |

Experiment-report classes (functions): absinthe `unknown` 373, `none` 75,
`possible_domain_escape` 2, `clause_conflict` 1; tesla `unknown` 300, `none`
12, `possible_domain_escape` 1. The product ledger counts slices, the
experiment counts functions; totals of both are in the reports.
`require_static_return` did not change any function class in either project.

## Unknown obligations by reason

| Reason | absinthe | tesla |
| --- | --- | --- |
| `top_only` | 151 | 324 |
| `no_counted_component` | 220 | 47 |
| `near_top` | 3 | 2 |
| Total | 374 | 373 |

By translation quality, unknowns split as follows.

| Reason / translation | absinthe | tesla |
| --- | --- | --- |
| `top_only`, approximate | 135 | 312 |
| `top_only`, exact | 16 | 12 |
| `no_counted_component`, approximate | 211 | 35 |
| `no_counted_component`, exact | 9 | 12 |
| `near_top`, approximate | 1 | 1 |
| `near_top`, exact | 2 | 1 |

Unknown share of compared slices: absinthe 374 of 453 (82.6 percent), tesla
373 of 387 (96.4 percent). The unknown reasons have not been reviewed against source.

## Findings

Absinthe: 9 findings, 7 gated (exit code 1). Tesla: 1 finding, 0 gated.

Gated (blocking):

| # | Rule / evidence | Subject | Clause | Prerequisites |
| --- | --- | --- | --- | --- |
| 1 to 7 | SL001 `return_conflict`, `clause_conflict` | `Absinthe.Blueprint.Input.parse/1` (`lib/absinthe/blueprint/input.ex:37`) | 1 to 7 | `no_unsupported_loss`, `no_overlap`, `no_arrow_in_return`, `no_arrow_polarity_argument`, `clause_contained` met; `clause_reachable` unchecked (does not block) |

The seven findings are one function and one slice, one per clause. The spec is
`parse(any()) :: nil | t()`; the clause returns are structs of
`Absinthe.Blueprint.Input.Integer`, `.Float`, `.Null`, `.String`, `.Boolean`,
`.List` and `.Object`. The report translation carries
`arrow_polarity`, `integer_refinement_erased`, `map_key_widened` and
`recursive_cutoff` losses, all classified as non-blocking approximation.
Whether `t()` covers those structs has not been examined.
This is the single largest incremental-effect target: any change that alters
the classification of clause return containment in the presence of
`recursive_cutoff` or `map_key_widened` will move these seven.

Informational (not gated):

| Project | Rule / evidence | Subject | Blocked prerequisite |
| --- | --- | --- | --- |
| absinthe | SL002 `possible_domain_escape` | `Absinthe.Phase.Init.run/2` (`phase/init.ex:9`), inferred extra `{:record_phases, %Blueprint{}, fun}` | `structured_possible` blocked; `no_arrow_polarity_argument` blocked |
| absinthe | SL002 `possible_domain_escape` | `Absinthe.Subscription.PipelineSerializer.pack/1` (`pipeline_serializer.ex:22`) | `structured_possible` blocked (reasons `domain_escape [0,1]`, `unknown_components 3`, `no_counted_component`, `return_inexact`) |
| tesla | SL002 `possible_domain_escape` | `Tesla.Adapter.Mint.read_chunk/3` (`adapter/mint.ex:76`), inferred extra `{:error, term()}` | `structured_possible` blocked (translation approximate: `opaque_boundary`; reasons include `input_approximate`, `tag_in_spec`, `subtraction_payload`, `payload_gradual`, `return_inexact`) |

SL001 findings that did not gate: none. Every SL001 in both projects gated,
so there is no blocked SL001 prerequisite to list. The three SL002 entries
above are the only findings without a gate; each is blocked on
`structured_possible` (the evidence stays `possible_domain_escape` rather
than the structured class), and `Phase.Init.run/2` additionally on
`no_arrow_polarity_argument`.

Ledger `possible_mismatch` counts (absinthe 3, tesla 1) are exactly these
findings (the gated function counts once as a slice).

No slice was `clause_conflict` in Tesla, and no `near_top` or `top_only`
slice was reported as a finding in either project.

## Runtime

| | absinthe | tesla |
| --- | --- | --- |
| `run.sh` wall clock (experiment + product) | 45 min 27 s (user 1170 s, sys 1053 s) | 7.8 s |
| Experiment report | about 39 min (08:42 to 09:21 by file timestamps) | a few seconds |
| Product `--ci` run | about 6 min by file timestamps; a separate re-run to a scratch file took 345 s and produced the same findings fingerprints and ledger | a few seconds |

Caveats. The Absinthe wall time was measured on a shared, loaded machine
(load average 4 to 10) and part of it overlapped read-only timing probes run
to find why the experiment was slow, so treat it as an upper bound of order
40 minutes, not a benchmark. It is far above Tesla (8 s). The cause is the experiment report, not analysis: the
uncompressed normalised experiment report is 740 MB (30 MB gzipped), with
per-component type strings up to about 470 KB, because Absinthe's blueprint
structs expand to very large `Descr` printouts in every component and clause
entry. The high system time suggests memory pressure. Per-module analysis
(`Analysis.module`) and `Evidence.classify` were measured in isolation and
each took under about 3 s per module. The product run does not print those
strings and stays near six minutes. `runtime_ms` is removed from the
normalised reports by design, so no in-report runtime exists.

Storage note. `absinthe.json.gz` is about 30 MB; the other expansion `.gz`
files are at most 0.3 MB. Committing it will grow the repository by that
amount. The summary `absinthe.json` (0.7 MB) and `absinthe.spec_lint.json`
(0.6 MB) carry the totals and every finding; the `.gz` is only needed to
inspect per-component detail. Decide before committing.

## Use as a holdout

Baseline numbers to compare later runs against: absinthe 7 gated SL001
(one function), 2 SL002, 374 unknown, 70 established; tesla 0 gated, 1 SL002,
373 unknown, 12 established. A later change is judged by the incremental
gates and unknown-to-established movement on these two, with triage of any
new gate done against source before the change is credited.
