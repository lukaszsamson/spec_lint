# Release campaign 1 (Milestone 5): correctness and runtime

The fifteen corpora (and the fixture corpus) replayed with one frozen tool
under the three qualified compilers, with provenance, resource
measurements, budgets, struct-default counts and the gate list for the
refutation phase. The frozen evaluation inventory is
`../../../evaluation/` (`e464905`); nothing here changes it.

## Frozen implementation

| | |
| --- | --- |
| Tool revision | `06b7496648a6bcc74487644b34be02957b9c5bc2` ("M5: resource failures, campaign measurement and gate tooling") |
| `source_sha256` | `b039ce7dd26a5991f6e7a86d8936af4a5977760696437c7f7d54bedbf78edded` (`provenance.sh`: `lib/`, `test/support/`, `mix.exs`, `bench/**/*.{exs,sh,jq,patch}`) |
| Worktree | a clean `git worktree` of that commit; every provenance file records `"dirty": false` and this digest |
| Configuration | the product default (`SPEC_LINT_PRODUCT_ONLY=1`, no product options: clause-local qualification on, review profile, `--ci --format json`) |

Every later campaign number (budgets, struct-default counts, gates) is
from reports produced by that revision. A change to anything the digest
covers is a new freeze and a new campaign.

## Toolchains

Both 1.21 compilers were rebuilt from fresh clones with the committed
`../../toolchain/build_elixir.sh` (`c24c235` from the fork
`https://github.com/lukaszsamson/elixir`, `ELIXIR_REPO`; `648b2a9` from
upstream), on Erlang/OTP 28.5.0.1. 1.20.4 is the asdf installation
`1.20.4-otp-29` (revision `759443e`), run on OTP 28.5.0.1 as in Milestone 3.
Identities (`qualification/*.identity.json`, `identity.exs`):

| Build | `code_digest` | `exck_digest` | Pinned build digest (preflight) |
| --- | --- | --- | --- |
| `c24c235` fresh | `59b3bff8...c500b` | `08604ec6...54da96` | `ae7d8dc2...c1e947` (qualified) |
| `648b2a9` fresh | `bb1eb6ff...fa116f` | `2166532d...829a39` | `cce56065...856cce` (qualified) |
| `~/elixir` (`c24c235`, earlier replays) | `19cf9a66...403def` | `80f75ead...94b22a2` | `ae7d8dc2...c1e947` |

The fresh `648b2a9` build has exactly the identity recorded in
`../../toolchain/upstream-1.21-648b2a9.md`. The fresh `c24c235` build does
not have `~/elixir`'s whole-build identity: its build date is the commit
time, and **two standard-library checker chunks differ** (`URI`,
`Logger.Backends.Console`). In both, the fresh `c24c235` chunks equal the
fresh `648b2a9` ones; the only stored-signature difference between the two
fresh builds is `IEx.Autocomplete`. So `~/elixir` is not a clean build of
its revision (probably incrementally built modules whose sources did not
change), and the Milestone 2 attribution of the `URI.to_string/1` and
`Logger.Backends.Console` differences to the 648b2a9 compiler change was
wrong: only `IEx.Autocomplete.exports/1` comes from the compiler. No report
changes (below). Preflight pins the checker, debug-info, typespec and
manifest modules, which are equal for both `c24c235` builds.

The fourteen OSS corpora were recompiled with each fresh 1.21 build into
separate build roots (`../../toolchain/compile_corpora.sh`); the 1.20.4
reports read the Milestone 3 builds of the same installation.

## Qualification of the frozen tree (`qualification/`)

| | `c24c235` | `648b2a9` | 1.20.4 |
| --- | --- | --- | --- |
| `mix format --check-formatted`, `mix credo --strict` | clean | clean | clean |
| `mix test` | 439 passed, 10 excluded | 439 passed, 10 excluded | 442 passed, 7 excluded |
| `mix test --only cross_compiler` (`SPEC_LINT_OTHER_ELIXIR`) | passes, 1.20.4 as the other | passes, 1.20.4 as the other | passes, `c24c235` as the other |
| `mix dialyzer` (own PLT per compiler) | 0 errors | 0 errors | 0 errors |
| Self-check `mix spec_lint --ci` | 407 slices, complete, exit 0 | 407 slices, complete, exit 0 | 407 slices, complete, exit 0 |

The excluded tests are the other line's adapter-pinned tests. Each gate
ran with its own `MIX_BUILD_PATH` and `SPEC_LINT_PLT_DIR`. The commit that
adds these reports adds one test (the budgets check, outside the frozen
digest); the four gates pass on it under all three compilers (440, 440 and
443 tests).

## Replay results

`c24c235/`, `648b2a9/`, `1.20.4/`: per corpus `NAME.spec_lint.json`,
`NAME.provenance.json`, `NAME.resources.json` (the measured run),
`NAME.rerun.resources.json` (the second run, with budgets enforced), the
fixture experiment report `fixtures.json` (its tool-build path is written
`$TOOL_BUILD`), `summary.json` (`compare_replay.sh` against the previous
reports of the adapter), `rerun_summary.json` (the second run against these
reports) and `struct_defaults.json`.

| Adapter | Previous reports | Compared slices | Unknown obligations | Findings | Gates | Exit 1 (gates) |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `1.21.0-dev+c24c235` | `../elixir-1.20.4/c24c235/` (tool `f364fa1`) | 4,204 | 3,113 | 63 | 9 | Absinthe, Ash, Oban |
| `1.21.0-dev+648b2a9` | `../upstream-648b2a9/` (tool `41f56c3`) | 4,204 | 3,113 | 63 | 9 | Absinthe, Ash, Oban |
| `1.20.4+759443e` | `../elixir-1.20.4/` (tool `f364fa1`) | 4,170 | 3,095 | 65 | 9 | Absinthe, Ash, Oban |

Every run is complete; every other corpus exits 0. Against the previous
reports of each adapter, every ledger, finding count, gate decision, exit
code and fingerprint is unchanged (no gate added or removed). The findings
differ only where Milestone 4 and the Milestone 3 review changed them:
the nine clause conflicts gained `data.source_clause`,
`data.clause_mapping` and a "source clause" detail row, and the rendered
details of `Ash.Test.refute_has_error/3` (SL002, not gating) lost a
redundant `and map()` (the `DescrWalk` open-map fix). The `beams` differ
for the 1.21 lines because the corpora were rebuilt: build paths, the BEAM
md5 of nondeterministically compiled modules (21 Phoenix LiveView, 3 Ash,
1 Nx, as in Milestone 2), 12-13 stdlib modules that record the build
directory or date, and the checker chunks of `URI`, `Logger.Backends.Console`
(stdlib) and of `Phoenix.LiveView.Utils` and a test router (callers of
`URI.to_string/1`) under `c24c235` (the `~/elixir` build difference
above). The 1.20.4 BEAMs are identical.

**Reproducibility.** A second run of the whole campaign (budgets
enforced) produced byte-identical reports, provenance and fixture reports
for all three adapters (`rerun_summary.json`: no differing key).

## Runtime and memory (`NAME.resources.json`)

Method: `run.sh` wraps the product run (`mix run bench/run_on_ebin.exs
... --ci --format json`, one corpus at a time, nothing else running) in
`/usr/bin/time -l`: wall is its `real` time (VM start included),
peak memory the maximum resident set size of the product VM. Machine:
Apple M2 Pro, 12 cores, 32 GB, macOS 26.7, OTP 28.5.0.1.

| Corpus | Wall s, run 1 / run 2 (c24c235; 648b2a9; 1.20.4) | Peak RSS MiB, run 1 / run 2 | Budget |
| --- | --- | --- | --- |
| absinthe | 57.5/55.1; 53.2/56.1; 56.3/54.4 | 6037/6157; 6199/6031; 6304/6338 | 90 s, 8,256 MiB |
| ash | 3.70/3.67; 3.69/3.40; 3.66/3.66 | 309/308; 304/308; 332/325 | 10 s, 448 MiB |
| stdlib | 1.53/1.31; 1.46/1.32; 1.49/1.34 | 429/424; 431/427; 420/442 | 5 s, 576 MiB |
| tesla | 0.95/0.95; 0.93/0.95; 0.99/0.98 | 167/163; 170/173; 186/196 | 5 s, 256 MiB |
| the other eleven | 0.47-0.80 | 119-169 | 5 s, 256 MiB |

Absinthe's product run takes 53-58 s on all three compilers (Milestone 1
recorded 73-75 s for the product run under `c24c235`); its peak RSS is
6.0-6.3 GB.

**Budgets** (`../../budgets.json`, checked by `run.sh` and by
`test/spec_lint/corpus_report_test.exs` against every committed
measurement): per corpus, wall = max(5 s, 1.5 x the maximum of the three
run-1 measurements, rounded up to 5 s); peak RSS = max(256 MiB, 1.3 x
that maximum, rounded up to 64 MiB). Both runs of every corpus under every
adapter are within budget. The budgets are for this machine class; a
slower CI machine needs its own measurement.

## Resource failures

`test/integration/resource_failure_test.exs` (all three compilers): an
analysis crash inside the run exits 2 and its report says `incomplete`; an
exception after the analysis exits 2 and writes no report (and removes an
earlier one); a VM killed with SIGKILL during the analysis leaves no report
at the output path. **An OOM-killed or otherwise signalled VM cannot
promise exit 2**: it exits with the signal's status and writes nothing, so
CI must treat a missing report, or one whose `completion.status` is not
`complete`, as a failure. `compare_replay.sh` does so for the corpus
reports (missing, truncated or incomplete: exit 2), and `run.sh` removes a
corpus's earlier outputs before running it.

## Struct-default violations (`*/struct_defaults.json`)

`../../../evaluation/struct_defaults.exs` (definition in the script)
tags a finding when every violating component of the returns it rests on
is a closed struct whose default-`nil` fields, outside their declared
types, are what puts it outside the spec. Counted separately; no policy
changed.

| Adapter | Findings | Struct-default findings | Of which gates | Gates that are not struct defaults |
| --- | ---: | ---: | ---: | --- |
| `c24c235` | 63 | 7 | 7 of 9 | `Oban.Registry.via/3`, `Ash.Page.page_opts/1` |
| `648b2a9` | 63 | 7 | 7 of 9 | the same |
| 1.20.4 | 65 | 7 | 7 of 9 | the same |

All seven are the clauses of `Absinthe.Blueprint.Input.parse/1`
(`source_location: nil`, declared `SourceLocation.t()`): five by the
subtype criterion (`Integer`, `Float`, `Null`, `String`, `Boolean`) and
two by the overlap criterion (`List`, `Object`, whose `items`/`fields`
are also inferred imprecisely). This is inventory family F16, the only
`struct_default` family. No non-gating finding is a struct default.

## Gates for the refutation phase (`gates.json`)

`../../gate_diff.sh` per adapter against the previous reports. All 27
gates (9 per adapter) are `changed`, none `new`, `unchanged` or `removed`;
every change is `data` only (the Milestone 4 source-clause fields), with
the fingerprint, evidence, prerequisites and message unchanged. `to_refute`
lists all 27.

## Regenerate

`$R` holds the fresh builds, `$ORIGINAL_OSS` and `$EXPANSION_OSS` the
checkouts of `../../README.md`, `$SRC` a checkout of `v1.20.4`, `$B120` the
1.20.4 corpus builds. From a clean worktree of `06b7496`, with
`ASDF_ERLANG_VERSION=28.5.0.1` and `SPEC_LINT_PRODUCT_ONLY=1`:

```sh
ELIXIR_REPO=https://github.com/lukaszsamson/elixir.git \
  bench/corpus/toolchain/build_elixir.sh c24c23538d521d25edd6a9a7a66fc5206caab70e $R/elixir-c24c235
bench/corpus/toolchain/build_elixir.sh 648b2a94934664cfd2c788348d02d799c68faa69 $R/elixir-648b2a9

# per 1.21 revision REV (MANIFEST: empty for c24c235 with expansion.json for
# the expansion corpora; toolchain/upstream-648b2a9.json for 648b2a9)
export PATH=$R/elixir-REV/bin:$PATH ELIXIR_DIR=$R/elixir-REV SPEC_LINT_COMPILER_REPO=$R/elixir-REV
export SPEC_LINT_CORPUS_BUILD=$R/corpus-REV MIX_BUILD_PATH=$R/tool-build/REV/test
SPEC_LINT_OSS=$ORIGINAL_OSS bench/corpus/toolchain/compile_corpora.sh jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS=$EXPANSION_OSS SPEC_LINT_CORPUS_MANIFEST=$PWD/bench/corpus/expansion.json \
  bench/corpus/toolchain/compile_corpora.sh req broadway oban phoenix_live_view ash nx absinthe tesla
SPEC_LINT_CORPUS_OUT=OUT/REV SPEC_LINT_OSS=$ORIGINAL_OSS SPEC_LINT_CORPUS_MANIFEST=$MANIFEST \
  bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_CORPUS_OUT=OUT/REV SPEC_LINT_OSS=$EXPANSION_OSS SPEC_LINT_CORPUS_MANIFEST=$MANIFEST_OR_EXPANSION \
  bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
SPEC_LINT_CORPUS_OUT=OUT/REV SPEC_LINT_PRODUCT_ONLY=0 SPEC_LINT_OSS=/dev/null bench/corpus/run.sh fixtures

# 1.20.4: ASDF_ELIXIR_VERSION=1.20.4-otp-29, ELIXIR_DIR=~/.asdf/installs/elixir/1.20.4-otp-29,
# SPEC_LINT_STDLIB_SOURCE=SPEC_LINT_COMPILER_REPO=$SRC, SPEC_LINT_CORPUS_BUILD=$B120,
# SPEC_LINT_CORPUS_MANIFEST=bench/corpus/toolchain/elixir-1.20.4.json for both calls.

# struct defaults, per adapter (placeholders of the provenance files)
MIX_ENV=test mix run bench/evaluation/struct_defaults.exs -- --out OUT/REV/struct_defaults.json \
  --path-var OSS=$ORIGINAL_OSS --path-var OSS=$EXPANSION_OSS --path-var BUILD=$R/corpus-REV \
  --path-var COMPILER=$R/elixir-REV --path-var ELIXIR=$R/elixir-REV OUT/REV

# from bench/corpus/reports
../compare_replay.sh release-1/c24c235 elixir-1.20.4/c24c235
../compare_replay.sh release-1/648b2a9 upstream-648b2a9
../compare_replay.sh release-1/1.20.4 elixir-1.20.4
../gate_diff.sh release-1/REV PREVIOUS    # combined into gates.json
```

The reports were written outside the worktree (so provenance saw it
clean) and copied here; `fixtures*.json` had the tool build path replaced
by `$TOOL_BUILD` afterwards (a path string only).
