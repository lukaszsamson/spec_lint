# Benchmark corpus bundle

The evidence behind EXPERIMENTS.md (Phase 0 and Phase 1) in a compact,
reproducible form: pinned corpora, the exact commands, the reports and the
nine real omissions as executable reproducers.

    bench/corpus/
      README.md        this file
      run.sh           regenerates reports/
      body_run.sh      regenerates reports/body/ (body-backend experiment)
      warnings7.patch  the Module.Types.warnings/7 hook body_run.sh needs
      reports/         one JSON pair per corpus (see below)
      reports/body/    body-backend experiment reports (see the last section)
      omissions/       README.md mapping the nine fixtures to their origin

The omission fixtures themselves are `test/support/omission_fixtures.ex`,
asserted by `test/spec_lint/omissions_test.exs`.

## Toolchain

| Component | Version |
| --- | --- |
| Elixir | 1.21.0-dev, `c24c235` (`c24c23538d521d25edd6a9a7a66fc5206caab70e`), built from a checkout of the fork `https://github.com/lukaszsamson/elixir` (the commit is on its branch `ls-mixed-into`; it is not upstream). The scripts take the checkout as `ELIXIR_DIR` (default `~/elixir`). |
| Erlang/OTP | 28 |
| Compiler adapter | `SpecLint.Compiler.V121` (`1.21.0-dev+c24c235`, checker `elixir_checker_v10`) |

## Corpora

| Corpus | What | Repository | Revision |
| --- | --- | --- | --- |
| `stdlib` | `lib/{elixir,eex,ex_unit,iex,logger,mix}/ebin` of the Elixir checkout | see "Component" above | `c24c235` (`c24c23538`) |
| `jason` | v1.4.5 | `https://github.com/michalmuskala/jason` | `4ede42858eb19f80ec9e863aab52df466eab8608` |
| `decimal` | | `https://github.com/ericmj/decimal` | `92a28e6b9a103f2b52a22b3f772f7a2a34b7b1d5` |
| `nimble_options` | | `https://github.com/dashbitco/nimble_options` | `825c05837f236c612c6ac2855735ec6cf7f2be69` |
| `mime` | | `https://github.com/elixir-plug/mime` | `23dcc1593ccc49648e33b9ed3c03bd516795f6d9` |
| `plug` | | `https://github.com/elixir-plug/plug` | `73404f851852a00ffb2014be95d4598900fa77b8` |
| `ecto` | | `https://github.com/elixir-ecto/ecto` | `94d69279c517347ff0962b138f4ccd0556486ae2` |
| `fixtures` | the project's own fixture modules (`SpecLint.ExperimentFixtures`, `SpecLint.Fixtures.*`, `SpecLint.OmissionFixtures`), not a pinned external revision | this repository | HEAD |

The expansion cohort of `expansion.json` (revisions there) comes from:

| Corpus | Repository |
| --- | --- |
| `req` | `https://github.com/wojtekmach/req` |
| `broadway` | `https://github.com/elixir-broadway/broadway` |
| `oban` | `https://github.com/sorentwo/oban` |
| `phoenix_live_view` | `https://github.com/phoenixframework/phoenix_live_view` |
| `ash` | `https://github.com/ash-project/ash` |
| `nx` | `https://github.com/elixir-nx/nx` (the `nx` subdirectory) |
| `absinthe` | `https://github.com/absinthe-graphql/absinthe` |
| `tesla` | `https://github.com/elixir-tesla/tesla` |

The URLs are the `origin` remotes of the checkouts the reports were made
from. They are not in `expansion.json` or `toolchain/upstream-648b2a9.json`
because those files are provenance inputs: their SHA-256 is recorded in
the committed provenance files. To make a checkout, with the qualified
toolchain on `PATH` (dependencies must be fetched and compiled under it,
as `toolchain/compile_corpora.sh` requires):

    git clone https://github.com/michalmuskala/jason $OSS/jason
    git -C $OSS/jason checkout --detach 4ede42858eb19f80ec9e863aab52df466eab8608
    (cd $OSS/jason && MIX_ENV=test mix deps.get)

The revisions are the output of `git -C <checkout> rev-parse HEAD` in the
checkouts used for every number in EXPERIMENTS.md. The libraries were
compiled with `MIX_ENV=test` so `_build/test/lib/<lib>/ebin` (and the ebin
of each dependency) exists.

## Commands

All commands run from the repository root. `$OSS` is the directory holding
the library checkouts, `$ELIXIR` the Elixir checkout.

The SL002 experiment (`bench/experiment.exs`) for one OSS library. Every
`_build/test/lib/*/ebin` of the library is on `--code-path`, so remote
types resolve:

    MIX_ENV=test mix run bench/experiment.exs -- \
      --ebin $OSS/ecto/_build/test/lib/ecto/ebin \
      --code-path $OSS/ecto/_build/test/lib/decimal/ebin \
      --code-path $OSS/ecto/_build/test/lib/ecto/ebin \
      --code-path $OSS/ecto/_build/test/lib/jason/ebin \
      --code-path $OSS/ecto/_build/test/lib/telemetry/ebin \
      --label ecto --out ecto.json

The stdlib (six `--ebin`, no `--code-path`):

    MIX_ENV=test mix run bench/experiment.exs -- \
      --ebin $ELIXIR/lib/elixir/ebin --ebin $ELIXIR/lib/eex/ebin \
      --ebin $ELIXIR/lib/ex_unit/ebin --ebin $ELIXIR/lib/iex/ebin \
      --ebin $ELIXIR/lib/logger/ebin --ebin $ELIXIR/lib/mix/ebin \
      --label stdlib --out stdlib.json

The `mix spec_lint --ci` pipeline over explicit ebins
(`bench/run_on_ebin.exs`), for projects SpecLint cannot be added to as a
dependency. `--root` is the project root; the app name of an ebin is its
parent directory name:

    MIX_ENV=test mix run bench/run_on_ebin.exs -- \
      --ebin $OSS/ecto/_build/test/lib/ecto/ebin \
      --code-path $OSS/ecto/_build/test/lib/decimal/ebin \
      --code-path $OSS/ecto/_build/test/lib/ecto/ebin \
      --code-path $OSS/ecto/_build/test/lib/jason/ebin \
      --code-path $OSS/ecto/_build/test/lib/telemetry/ebin \
      --root $OSS/ecto --ci --format json --output ecto.spec_lint.json

`run.sh` issues exactly these invocations for every corpus. Two optional
variables serve option comparisons: `SPEC_LINT_PRODUCT_ARGS` appends options
to the product run (the report's `config` records them) and
`SPEC_LINT_PRODUCT_ONLY=1` skips the experiment report, which has no product
options. The `fixtures`
corpus stages the fixture beams from `_build/test/lib/spec_lint/ebin` into a
temporary `fixtures/ebin` directory and puts the spec_lint ebin on
`--code-path`.

## Regenerating

    # 1. Check out and compile the libraries at the pinned revisions.
    for lib in jason decimal nimble_options mime plug ecto; do
      (cd $OSS/$lib && git checkout <revision> && MIX_ENV=test mix deps.get \
        && MIX_ENV=test mix compile)
    done

    # 2. Regenerate everything (about 20 seconds), or name corpora.
    SPEC_LINT_OSS=$OSS ELIXIR_DIR=$ELIXIR bench/corpus/run.sh
    SPEC_LINT_OSS=$OSS bench/corpus/run.sh mime plug

Requirements: `bash` 3.2 or later (the macOS system bash is enough: the
scripts use no associative arrays and expand possibly empty arrays safely
under `set -u`), `jq` (1.6 or later), the pinned toolchain on `PATH`. Both
scripts were last run under `/bin/bash` 3.2.57.
The script warns when a checkout is not at the pinned revision. Reports are
normalised: machine paths become `$OSS`, `$ELIXIR`, `$SPEC_LINT` and `$TMP`,
keys are sorted and the wall-clock `totals.runtime_ms` is removed, so two runs
of the same code from the same directories produce byte-identical files and
`git diff` on `reports/` shows only real changes. From other directories
(another machine, a fresh clone) they do not: BEAM files record the
directory they were built in, so the `beams` md5 values of some modules, the
provenance artifact hashes and `loaded_module_types_sha256` differ. Use
`compare_replay.sh` there; `differing_report_keys` should be only `beams`.
The path-independent compiler identity is `toolchain.identity` in the
provenance files (`toolchain/identity.exs`).

## Reports

Two files per corpus in `reports/`:

- `NAME.json`, the experiment report: per-function, per-slice and
  per-clause classes, components, loss kinds, near-top and top-only flags,
  totals, and for `fixtures` the accuracy against
  `SpecLint.ExperimentFixtures.expected/0`.
- `NAME.spec_lint.json`, the `mix spec_lint --ci` JSON report over the same
  ebins (no `fixtures`). All seven complete with exit code 0 and no
  blocking finding; the findings are SL002 informational reports (stdlib
  33, ecto 4, decimal 2, the rest 0).

Provenance: **all fifteen files were regenerated for this bundle**, with the
classifier at this repository's HEAD (after the post-Phase 1 review fixes
and the four external review fixes). The earlier results in the session
scratchpad (`results_phase1`, not durable) were not copied: they were
produced by the classifier at `70316ce`, before those fixes, they carry
absolute machine paths and `stdlib.json` was 5.0 MB. Compared with Phase 1 the function
class counts are identical for jason, decimal, nimble_options, mime, plug
and ecto. Only the stdlib moved, by the post-review change already recorded
in EXPERIMENTS.md ("Post-Phase 1 review re-measurement"): unknown 1035 to
1033, possible_domain_escape 11 to 13 (`DateTime.from_iso8601/2,3`).

Size: every file is under 2 MB, the largest are `ecto.json` (1.2 MB) and
`plug.json` (0.8 MB). **`stdlib.json` is stored in reduced form** (5.0 MB
in full): the run label, ebins, code paths, adapter, totals with all class
counts and loss kinds, and every function whose class is neither `none`
nor `unknown` (19 functions), with the key `reduced` stating so. The full
report is produced by the raw `bench/experiment.exs` stdlib command above;
`run.sh` reduces any report over 2 MB automatically.

Headline numbers of the current reports (functions / classes):

| Corpus | Functions | Classes |
| --- | --- | --- |
| stdlib | 1711 | unknown 1033, none 659, possible_domain_escape 13, possible_input_approximate 4, structured_possible 2 |
| jason | 20 | unknown 16, none 4 |
| decimal | 46 | unknown 28, none 16, possible_domain_escape 2 |
| nimble_options | 5 | unknown 5 |
| mime | 5 | none 5 |
| plug | 86 | unknown 79, none 7 |
| ecto | 165 | unknown 137, none 24, possible_domain_escape 4 |
| fixtures | 94 | clause_conflict 15, structured_possible 6, possible_domain_escape 8, possible_input_approximate 5, unknown 28, none 32 |

None of the corpora in this table (stdlib and the six original libraries)
has a `clause_conflict` function, which is the one gating class: gating
recall on the nine known real omissions is 0 of 9 (see
`omissions/README.md`). The expansion cohort does: `Oban.Registry.via/3`,
`Ash.Page.page_opts/1` and seven clauses of `Absinthe.Blueprint.Input.parse/1`
(`expansion_triage.md`, `holdout2_baseline.md`,
`clause_local_qualification.md`). The fixtures row was regenerated for the
clause-local qualification experiment: it adds the two clause-local omission
stand-ins and nine control functions (`SpecLint.Fixtures.ClauseLocal`),
which account for all 11 new functions; the classes of the 83 earlier
fixture functions and the fixture accuracy block are unchanged.

## Body-backend experiment (`reports/body/`)

These are the reports behind EXPERIMENTS.md "Body backend experiment",
written by `bench/body_experiment.exs`. The runner needs a build of
`c24c235` carrying the `Module.Types.warnings/7` hook; it cannot run under
the plain toolchain. The hook is the `lib/elixir/lib/module/types.ex` hunk
of commit `b88a257a3` (`b88a257a3008b60fcf843c70390734dacad445d5`, on the
branch `ls-typespec-tightening` of the fork
`https://github.com/lukaszsamson/elixir`; not upstream), committed here as
`warnings7.patch` (25 lines added, 3 removed). Build it and run:

    git clone https://github.com/lukaszsamson/elixir.git $ELIXIR_BODY
    git -C $ELIXIR_BODY checkout --detach c24c235
    git -C $ELIXIR_BODY apply $PWD/bench/corpus/warnings7.patch
    make -C $ELIXIR_BODY compile

    ELIXIR_BODY=$ELIXIR_BODY SPEC_LINT_OSS=$OSS \
      [SPEC_LINT_OSS_BODY=/path/to/oss-body] bench/corpus/body_run.sh

`body_run.sh` recompiles decimal, plug and ecto with that build into a
separate `MIX_BUILD_PATH` (`SPEC_LINT_OSS_BODY`, default a temporary
directory), so the pinned checkouts are not touched.

Files:

- `fixtures.json`: the omission reproducers and the experiment fixtures.
- `enum_keyword.json`: cost on `Enum` and `Keyword`.
- `decimal.json`, `plug.json`, `ecto.json`: the omission modules plus 30
  random other modules (seed 20260928).
- `*_full.json`: every module of each library, as totals, omissions, class
  changes and one row per function.

Each report keeps full detail only for omissions, for functions whose class
or warning differs between modes, and for functions with an extra checker
diagnostic. Every function has a row in `function_rows`. Paths are
normalised as above.

Each mode entry records the class, the reasons and, since the external
review, whether the obligation is established (`established`: `U(D)`
within `S_lo`, DESIGN.md section 3) and whether the spec return translates
exactly (`return_exact`). A class of `none` only says that the extra over
`S_hi` is empty; with an inexact return it is "compatible at available
precision", not established.

The cost fields (`body_us`, `default_run_us`, `totals.cost`) are wall-clock
times, so two runs differ there. Everything else is deterministic: the
last regeneration (adding `established` and `return_exact`) left every
other field of every report unchanged.

## Expanded cohort (2026-09-29)

`expansion.json` freezes Req, Broadway, Oban, Phoenix LiveView, Ash and Nx
revisions. Ash and Nx were held out during classifier and precision work;
no production inference or classifier change was adopted before their run.
See `expansion_triage.md` for source judgments and independently executable
Req/Oban counterexamples. `precision_ceiling.md` measures the limits of
improving input lower bounds on the nine stand-in omission fixtures.

Prepare separate checkouts at the manifest revisions, then run
`MIX_ENV=test mix deps.get` and `MIX_ENV=test mix compile` under the qualified
compiler in each project (`nx/nx` for Nx). Set PATH explicitly when a
project's `.tool-versions` selects a different compiler. Dependency lockfiles,
BEAM hashes and the loaded compiler's BEAM hash are recorded in provenance.

```sh
SPEC_LINT_OSS=/path/to/isolated/checkouts \
SPEC_LINT_CORPUS_MANIFEST="$PWD/bench/corpus/expansion.json" \
SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/expansion" \
bench/corpus/run.sh req broadway oban phoenix_live_view ash nx

elixir bench/corpus/expansion_witnesses.exs /path/to/isolated/checkouts
```

The runner rejects wrong revisions unless `SPEC_LINT_ALLOW_UNPINNED=1` is
explicitly set for an exploratory run. Exit 1 from the product is a finding,
not a runner failure; exit 2 or incomplete results fail the benchmark and
retain logs. Large reports retain the complete normalized JSON as `.json.gz`
and a checked summary as `.json`. Previous historical reduced reports are
not retroactively upgraded; regenerate them to get full detail/provenance.
The provenance file includes artifact paths, source and lock identities, the
loaded compiler hash, and a content digest of the tool's analysis scripts and
implementation. A dirty flag alone is not an identity. Paths are written with
the same placeholders as the reports (`$OSS`, `$ELIXIR`, `$COMPILER`, `$TMP`,
`$SPEC_LINT`); the sha256 values carry the identity and do not depend on
them. Provenance files written before 2026-09-29 were rewritten to these
placeholders in place, with no other change.

`req.consumer.json` additionally exercises the actual Mix task. Reproduce in
a separate Req checkout at the same revision by adding
`{:spec_lint, path: "/path/to/spec_lint", runtime: false}` to `deps/0`, then
run `MIX_ENV=test mix spec_lint --ci --format json --output req.consumer.json`
under the qualified toolchain. This installs the task as a dependency;
putting its BEAM directory on `-pa` alone does not provide a valid Mix
consumer installation. The corpus checkouts themselves remain unchanged.

The body experiment now distinguishes `gate` (SL001 prerequisites),
`candidate` (structured SL002 evidence), and `reported` (any SL001/SL002
finding); legacy `warn`/`detected` combine gates and structured candidates.
Do not quote legacy `detected` as gated recall. Failed analysis is unavailable,
not a negative result. The new `reports/expansion/body_fixtures.json` reruns
fixtures with those metrics; older body reports retain their historical schema.

## Clause-local qualification experiment (2026-09-29)

`reports/expansion/clause_local/{off,on}/` hold product reports
(`NAME.spec_lint.json`) and provenance for all fifteen real-code corpora
(stdlib, the six original libraries, the six expansion projects and the
absinthe/tesla holdouts), from one frozen tool tree, without and with
`--clause-local-qualification`. The experiment report does not depend on
product options, so these runs skip it:

```sh
SPEC_LINT_PRODUCT_ONLY=1 SPEC_LINT_PRODUCT_ARGS=--clause-local-qualification \
SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/expansion/clause_local/on" \
SPEC_LINT_OSS=$OSS bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto

SPEC_LINT_PRODUCT_ONLY=1 SPEC_LINT_PRODUCT_ARGS=--clause-local-qualification \
SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/expansion/clause_local/on" \
SPEC_LINT_CORPUS_MANIFEST="$PWD/bench/corpus/expansion.json" \
SPEC_LINT_OSS=/path/to/isolated/checkouts \
bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
```

Leave out `SPEC_LINT_PRODUCT_ARGS` and write to `off/` for the baseline
reading. Tesla needs the qualified compiler selected explicitly (its
`.tool-versions` names 1.19; see `holdout2_baseline.md`). Results and triage:
`clause_local_qualification.md`. Since the Close phase the qualification is
the default, so `SPEC_LINT_PRODUCT_ARGS=--no-clause-local-qualification`
gives the `off/` reading on the current tree.

`reports/expansion/clause_local/default/` holds the confirmation runs of the
Close phase: product-only reports with the final tree and the default
configuration (qualification on, compiler check of `clause_reachable`), for
the stdlib and the two fresh holdouts, written with
`SPEC_LINT_CORPUS_OUT=.../clause_local/default` and no product arguments.
The top-level `reports/NAME.spec_lint.json` and
`reports/expansion/NAME.spec_lint.json` were not regenerated; they are the
Phase 2 baselines, taken with the qualification off.

## Other artefacts of the 2026-09-29 Close phase

- `reports/expansion/ash_integration_witnesses.json`: the output of
  `elixir bench/corpus/ash_integration_witnesses.exs /tmp/spec-lint-expansion`
  after the review repaired its inputs (`holdout_triage.md`).
- `compiler_counterexamples/`: minimal modules, with a self-checking
  script, for the two compiler inference limits behind most known misses
  (helper insensitivity and `Enum.map/2` results).

## Phase 4 regression replay

`reports/phase4/` retains the replay after guard-feasibility qualification and
required-check failure handling. See its README for regeneration and the
interrupted preliminary Absinthe attempt. `PHASE_4_PLAN.md` records the final
gates and remaining limits. These projects are regression corpora, not fresh
holdouts for the helper experiment.

## Milestone 1 replay

`reports/m1/` holds the product-only replay of all fifteen corpora after
type printing was removed from classification, with provenance, a
`summary.json` produced by `compare_replay.sh` against `reports/phase4/` (and
against `reports/expansion/clause_local/on/` for Absinthe, which Phase 4
lacks) and the Absinthe timings. See its README.

## Upstream compiler qualification (Milestone 2)

`toolchain/` holds what qualifies upstream Elixir `648b2a9` next to the
fork revision `c24c235`: `build_elixir.sh` (clean-clone build of any
upstream revision), `identity.exs` (path-independent build identity),
`compile_corpora.sh` (recompiles corpus checkouts with another compiler
into separate build paths, read by `run.sh` through
`SPEC_LINT_CORPUS_BUILD` and written as `$BUILD`), the replay manifest
`upstream-648b2a9.json`, the build record `upstream-1.21-648b2a9.md` and
the internals audit `audit-648b2a9.md`. `reports/upstream-648b2a9/` holds
the fifteen-corpus replay under the upstream compiler, compared with
`reports/m1_review/`; see its README.


## Elixir 1.20.4 qualification (Milestone 3)

`toolchain/audit-1.20.4.md` audits every compiler internal the adapters
read on Elixir 1.20.4 against 1.21 (35 rows, each probed;
`toolchain/audit_probe.exs` prints them on any build). The replay is
`reports/elixir-1.20.4/` (see its README): the fifteen corpora compiled
with 1.20.4 into separate build paths and analysed by
`SpecLint.Compiler.V120`, the same corpora under `c24c235` with the same
tool (`reports/elixir-1.20.4/c24c235/`), their comparison
(`toolchain/compare_lines.sh`) and per-adapter baselines. `run.sh` gained
`SPEC_LINT_STDLIB_SOURCE` (a checkout the stdlib corpus of an installed
release is checked against), `SPEC_LINT_BASELINE_DIR` and
`SPEC_LINT_WRITE_BASELINE_DIR`; `toolchain/elixir-1.20.4.json` is the
replay manifest.


## Release campaign tooling (Milestone 5)

- **Stale outputs.** `run.sh` removes a corpus's earlier outputs in the
  output directory (report, `.gz`, provenance, logs, resources) before it
  runs the corpus, so an interrupted or killed run cannot leave an earlier
  run's report in place.
- **Resources.** The product run is wrapped in `/usr/bin/time -l` (macOS;
  `-v` with GNU time). `NAME.resources.json` records its wall time
  (`real`), the maximum resident set size of the process tree it waited for
  (the product VM), the macOS peak memory footprint, the method and the
  platform. These files are measurements, not deterministic output.
- **Budgets.** `budgets.json` holds a wall-time (`wall_s`) and peak-RSS
  (`max_rss_mb`) budget per corpus; `SPEC_LINT_BUDGETS` selects another
  file (`none` disables the check). A corpus over either budget fails the
  runner with exit 2 after all named corpora ran, keeping its report and
  recording `budget.within: false` in its resources file.
- **`compare_replay.sh`** fails closed: a report that is missing (including
  a corpus with only its provenance, or one present in a baseline
  directory), unreadable (truncated, not JSON) or not `complete` is listed
  in `incomplete`, makes `all_unchanged` false and exits 2 after the
  summary is printed.
- **`gate_diff.sh NEW BASE`** lists every gated finding of NEW as `new`,
  `changed` (with the differing keys) or `unchanged` against BASE, and
  BASE's gates that NEW lacks as `removed`: the input of the refutation
  phase (`reports/release-1/gates.json`).
- **`../evaluation/struct_defaults.exs`** tags the findings whose extra
  return is a struct whose only violation is a default-`nil` field (the
  definition is in the script), per adapter, without changing any finding
  or policy.

The release campaign itself is `reports/release-1/` (see its README);
`budgets.json` was derived from its measurements.
