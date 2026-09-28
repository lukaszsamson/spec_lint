# SpecLint

SpecLint checks Dialyzer-style `@spec` declarations against the types the
Elixir compiler infers. It reads your compiled BEAM files, translates each
spec clause into the compiler's set-theoretic type lattice, and compares it
with the inferred signature the compiler stores in the `ExCk` chunk. It runs
no Dialyzer, needs no PLT, never starts your application, and its analysis
never calls your functions. Compilation still runs your macros.

The design, evidence model and measurements are in [`DESIGN.md`](DESIGN.md)
and [`EXPERIMENTS.md`](EXPERIMENTS.md).

## Requirements

SpecLint reads compiler internals that change between Elixir development
revisions, so each release supports specific compiler builds:

| SpecLint | Elixir | Checker chunk |
| --- | --- | --- |
| 0.1.0 | 1.21.0-dev, revision `c24c235` | `elixir_checker_v10` |

On any other compiler, `mix spec_lint` reports "unsupported compiler". In
CI mode (`--ci`) that exits with status 2.

Your modules need debug info, which is the Mix default. Specs are read from
the debug info chunk. A module compiled without it is reported as `SL008`.

## Installation

```elixir
def deps do
  [
    {:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

## Usage

```
mix spec_lint                                 report findings, exit 0
mix spec_lint --ci                            fail on new gated findings (exit 1)
mix spec_lint --ci --profile soundness        SL001, SL003 and coverage only
mix spec_lint --explain MyApp.Store.lookup/1  show the whole comparison for one function
mix spec_lint --format json --output spec-lint.json
mix spec_lint.baseline                        write .spec_lint_baseline.json
```

`mix spec_lint` compiles the project first. Its options are parsed before
compiling, so an invalid option fails without side effects.

| Option | Meaning |
| --- | --- |
| `--ci` | Gate findings: exit 1 on new gated findings or coverage violations. |
| `--profile soundness\|review` | Evidence policy (default `review`). |
| `--warnings-as-errors` | Gate every reported finding, including report-only ones. Works locally too. |
| `--format console\|json` | Report format (default `console`). |
| `--output PATH` | Write the report to `PATH` (written atomically). |
| `--baseline PATH` | Baseline file (default `.spec_lint_baseline.json`). |
| `--config PATH` | Configuration file (default `.spec_lint.exs`). |
| `--module Mod` | Analyse only this module. Repeatable. Makes the run partial. |
| `--app app` | Analyse only this umbrella child. Repeatable. Makes the run partial. |
| `--explain Mod.fun/arity` | Explain one function. |
| `--rules ID,...` | Run only these rules (IDs or names). Enables rules that are off by default. |
| `--except ID,...` | Do not run these rules. |
| `--require-static-return` | Treat structured evidence supported only by gradual clause returns as `possible_gradual`. |

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | Accepted. Without `--ci` or `--warnings-as-errors`, findings never fail the run. |
| 1 | New gated findings, or a coverage violation. |
| 2 | Invalid options or configuration, compilation failure, unsupported compiler (in CI) or backend, a filter that matches nothing, or an incomplete run (an internal failure while analysing a module). |

## Rules

| Rule | Meaning | Default |
| --- | --- | --- |
| `SL001 return_conflict` | Any normal return in a spec slice would be outside the spec. This covers the whole slice, or one contained inferred clause (`clause_conflict`). | warning, gated in both profiles |
| `SL002 possible_missing_return` | The inferred return may include alternatives the spec omits. | warning, informational: never gated by the evidence policy |
| `SL003 spec_domain_rejected` | No inferred clause accepts the spec's arguments. The checker would warn on every call in the slice. | warning, gated in both profiles |
| `SL004 possible_missing_input` | The implementation accepts inputs outside the spec domain. | off (hint) |
| `SL005 return_can_be_narrower` | The spec return is wider than every inferred return. | off (hint) |
| `SL006 possible_unexpected_return` | A `no_return()` spec whose implementation may return. | warning, gated in `review` |
| `SL007 spec_domain_body_warning` | Needs the body analysis backend, which no supported build has. Requesting it exits 2. | off |
| `SL008 analysis_unavailable` | A module or spec slice could not be analysed. | warning, gated unless acknowledged in the baseline |

A gated finding still has to meet its prerequisites to fail the build:

- no untranslatable construct;
- no overlapping spec clauses;
- no function type in the return.

`--explain` prints which prerequisite blocked gating. A rule's severity
only changes how a finding is printed, never whether it gates.

Wording is deliberate. A conflict says that any normal return *would be*
outside the spec. Inference over-approximates and never proves that a
return happens.

SL002 is informational because of measurement. On the stdlib and six OSS
libraries it had 0 true positives, and every real omission found by hand
landed in a class that does not warn (`EXPERIMENTS.md`). SL002 still
reports `possible_domain_escape`, `possible_input_approximate` and
`whole_kind_possible` findings. They are worth a look, and they gate only
under `--warnings-as-errors`.

## Configuration

`.spec_lint.exs` at the project root. Unknown keys are rejected.

```elixir
[
  analysis: :signatures,
  profile: :review,
  baseline: ".spec_lint_baseline.json",
  rules: [
    possible_missing_return: :warning,
    possible_missing_input: :off,
    return_can_be_narrower: :off
  ],
  coverage: [fail_on_regression: true, floor: 0],
  exclude: ["lib/generated/**"],
  expand_opaque: false,
  require_static_return: false,
  warnings_as_errors: false
]
```

- **`rules`** are keyed by name or ID (`SL002: :info`). A value is a
  severity (`:error`, `:warning`, `:info`, `:hint`) or `:off`.
- **`exclude`** globs match source paths relative to the project root.
  Excluded modules are counted in the ledger.
- **`coverage: [floor: n]`** fails CI when fewer than `n` spec slices are
  compared.
- **`coverage: [fail_on_regression: false]`** reports coverage regressions
  without failing on them.
- Command-line options override the file.

## Baseline

```
mix spec_lint.baseline
```

This writes `.spec_lint_baseline.json`. The file has two parts:

- every reported finding, with a structural fingerprint;
- an inventory of every analysed spec slice.

Review the file and commit it. You can add a `reason`, an `owner` and an
`expires` date (`"2026-12-31"`) to each finding. When you regenerate the
file, those values are kept for entries that still match.

- **Suppression.** A finding whose fingerprint is in the baseline does not
  fail CI. An entry past its `expires` date counts as new.
- **What the fingerprint hashes.** It covers the rule, the MFA, the slice
  and clause index, and the spec clause's structure with lines removed. It
  also covers the translated types, the translation losses and the inferred
  clauses the finding rests on. It survives line changes, reordering other
  functions and recompilation. It changes when the spec, its clause order
  or the inferred signature changes.
- **Coverage.** Every `unsupported` or `unavailable` slice, and every
  module without debug info, must be acknowledged in the inventory.
  Otherwise CI exits 1. A slice that the inventory lists as compared and
  that can no longer be analysed is a regression.
- **Stale entries.** They are listed as warnings and never fail a run. A
  partial run (`--module`, `--app`) never declares entries stale.
- **Compiler changes.** A baseline written for another compiler adapter is
  not applied. In CI that is exit 2. Regenerate the file deliberately.

`mix spec_lint` never modifies the baseline.

## JSON report

`--format json` writes a versioned envelope (`"schema": "spec_lint/report"`,
`"schema_version": 1`) with:

- tool, adapter, Elixir, OTP and checker chunk versions;
- BEAM hashes;
- the configuration digest;
- scope and capabilities;
- findings, with prerequisites, fingerprints and baseline decisions;
- the coverage ledger, per function and slice;
- baseline decisions, including stale entries;
- completion status and exit code.

Keys are sorted and paths are relative to the project root. Two runs on the
same inputs give byte-identical files.

## Coverage ledger

Every run reports what it did and did not analyse, with denominators:

- modules discovered and analysed;
- modules unavailable, by reason;
- specs out of scope, by category: macros, protocol dispatch functions,
  `behaviour_info/1`, generated definitions, private functions, Erlang
  modules and excluded modules;
- slices compared, exact or approximate, unsupported and unavailable;
- obligations established, compatible after approximation, possible
  mismatches and unknown.

A project with no eligible specs succeeds and says so.

## Running on a project you cannot modify

`bench/run_on_ebin.exs` runs the same pipeline over explicit ebin
directories:

```
MIX_ENV=test mix run bench/run_on_ebin.exs -- \
  --ebin path/to/_build/test/lib/plug/ebin \
  --code-path path/to/_build/test/lib/mime/ebin \
  --root path/to/plug --ci
```

## Development

```
mix format --check-formatted
mix credo --strict
mix test          # includes the consumer integration test (test/integration)
mix dialyzer      # PLT in priv/plts
```
