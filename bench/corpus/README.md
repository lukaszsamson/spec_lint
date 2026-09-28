# Benchmark corpus bundle

The evidence behind EXPERIMENTS.md (Phase 0 and Phase 1) in a compact,
reproducible form: pinned corpora, the exact commands, the reports and the
nine real omissions as executable reproducers.

    bench/corpus/
      README.md        this file
      run.sh           regenerates reports/
      reports/         one JSON pair per corpus (see below)
      omissions/       README.md mapping the nine fixtures to their origin

The omission fixtures themselves are `test/support/omission_fixtures.ex`,
asserted by `test/spec_lint/omissions_test.exs`.

## Toolchain

| Component | Version |
| --- | --- |
| Elixir | 1.21.0-dev, `c24c235` (built from `~/elixir`, `git -C ~/elixir rev-parse --short HEAD` prints `c24c23538`) |
| Erlang/OTP | 28 |
| Compiler adapter | `SpecLint.Compiler.V121` (`1.21.0-dev+c24c235`, checker `elixir_checker_v10`) |

## Corpora

| Corpus | What | Revision |
| --- | --- | --- |
| `stdlib` | `lib/{elixir,eex,ex_unit,iex,logger,mix}/ebin` of the Elixir checkout | `c24c235` (`c24c23538`) |
| `jason` | v1.4.5 | `4ede42858eb19f80ec9e863aab52df466eab8608` |
| `decimal` | | `92a28e6b9a103f2b52a22b3f772f7a2a34b7b1d5` |
| `nimble_options` | | `825c05837f236c612c6ac2855735ec6cf7f2be69` |
| `mime` | | `23dcc1593ccc49648e33b9ed3c03bd516795f6d9` |
| `plug` | | `73404f851852a00ffb2014be95d4598900fa77b8` |
| `ecto` | | `94d69279c517347ff0962b138f4ccd0556486ae2` |
| `fixtures` | the project's own fixture modules (`SpecLint.ExperimentFixtures`, `SpecLint.Fixtures.*`, `SpecLint.OmissionFixtures`), not a pinned external revision | this repository's HEAD |

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

`run.sh` issues exactly these invocations for every corpus. The `fixtures`
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

Requirements: `bash`, `jq` (1.6 or later), the pinned toolchain on `PATH`.
The script warns when a checkout is not at the pinned revision. Reports are
normalised: machine paths become `$OSS`, `$ELIXIR`, `$SPEC_LINT` and `$TMP`,
keys are sorted and the wall-clock `totals.runtime_ms` is removed, so two runs
of the same code produce byte-identical files and `git diff` on `reports/`
shows only real changes.

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
scratchpad (`results_phase1`) were not copied: they were produced by the
classifier at `70316ce`, before those fixes, they carry absolute machine
paths and `stdlib.json` was 5.0 MB. Compared with Phase 1 the function
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
| fixtures | 83 | clause_conflict 10, structured_possible 6, possible_domain_escape 7, possible_input_approximate 4, unknown 26, none 30 |

No corpus of real code has a `clause_conflict` function, which is the one
gating class: gating recall on the nine known real omissions is 0 of 9
(see `omissions/README.md`).
