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

SpecLint reads compiler internals that change between Elixir releases and
development revisions, so each release supports specific compiler builds:

| SpecLint | Elixir | Source | Checker chunk | Adapter id | Status | Known compiler defects |
| --- | --- | --- | --- | --- | --- | --- |
| 0.1.0 | 1.21.0-dev, revision `648b2a9` | upstream `elixir-lang/elixir` | `elixir_checker_v10` | `1.21.0-dev+648b2a9` | qualified (`bench/corpus/toolchain/audit-648b2a9.md`) | `for ... into:` with a collectable that may be a bitstring or a list narrows the body to `bitstring()` in the stored signature, which can make SpecLint gate a correct spec (audit row 19) |
| 0.1.0 | 1.21.0-dev, revision `c24c235` | fork `lukaszsamson/elixir`, branch `ls-mixed-into` | `elixir_checker_v10` | `1.21.0-dev+c24c235` | qualified (the development revision) | none known |
| 0.1.0 | 1.20.4 (revision `759443e`, the precompiled release) | upstream release `v1.20.4` | `elixir_checker_v8` | `1.20.4+759443e` | qualified, with its own baselines (`bench/corpus/toolchain/audit-1.20.4.md`) | none known; Erlang `-nominal` types are left out by its `Code.Typespec` (a reference to one is an unresolved remote type) |
| | 1.19 and earlier, 1.20.0 to 1.20.3 | | | | refused by Mix (exit 1, see below) | |
| | other 1.20.x releases, other 1.21 builds | | | | not supported (exit 2 in CI) | |

All on Erlang/OTP 28 (1.20.4 also passes preflight on OTP 29). SpecLint
picks the adapter for the running compiler from its version and checker
chunk version. `mix.exs` requires `~> 1.20.4 or ~> 1.21-dev`, so on 1.19,
1.20.0 to 1.20.3 or older releases Mix refuses to run the task before
SpecLint starts ("You're trying to run :spec_lint on Elixir v1.19.4 but it
has declared in its mix.exs file it supports only ...") and exits with
status 1, the same status as new gated findings: a CI job on such a
compiler cannot tell the two apart from the status alone. On a compiler
inside that range that is not a qualified build (another 1.20.x release,
another 1.21 development revision), `mix spec_lint` reports "unsupported
compiler" and names the supported ones; in CI mode (`--ci`) that exits
with status 2. The revision alone does not qualify a build:
preflight also compares the code of the checker modules with the
qualified build's (a patched checkout of a qualified commit is
unsupported) and probes every compiler internal SpecLint uses; a missing
or changed one is reported the same way.
`bench/corpus/toolchain/build_elixir.sh` builds a qualified upstream
revision from a clean clone.

The two 1.21 revisions are both `1.21.0-dev`, so Mix does not recompile a
project when you switch between them. `mix spec_lint` records which build
produced the project's BEAM files (`_build/ENV/lib/APP/.mix/spec_lint.build`)
and recompiles with `--force` when that is not the running build,
including the first time it runs on a project it did not compile itself.
Switching between 1.20.4 and 1.21 recompiles in any case. BEAM files of
the other compiler line are never analysed: without the Mix task (an
explicit ebin, `SpecLint.Run`), a build record of the other line, or its
checker chunks, make the run fail with exit status 2. The forced
recompilation also runs when `compile` already ran in the same VM (`mix do
compile + spec_lint`, an alias such as `["compile", "spec_lint --ci"]`);
if it still compiles nothing, the task exits 2 instead of recording the
other build's files as its own. A dependency whose BEAM files carry the
other line's checker chunks (possible with `--no-deps-check`, a shared or
stale build directory, or vendored BEAM files) also exits 2: the running
checker would ignore its signatures. Recompile it with `mix deps.compile
--force`. A dependency built by the other 1.21 build writes the same chunk
version and is not detected.

Baselines record the adapter id, so switching compilers is an adapter
change: a baseline written under another one is not applied, and
`mix spec_lint --ci` exits 2 asking you to review and regenerate it with
`mix spec_lint.baseline`. Keep one baseline per compiler you run in CI. On
the fifteen benchmark corpora no fingerprint differs between the two 1.21
revisions. Between 1.20.4 and 1.21 the findings and gates are the same
outside the standard library, but only 28 of the 65 finding fingerprints
are shared (5 of 30 outside the standard library, none of Absinthe's 9):
they differ wherever a map or struct type is involved, because the two
lines encode those types differently
(`bench/corpus/reports/elixir-1.20.4/README.md`).

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
mix spec_lint --format json > spec-lint.json  stdout carries only the JSON report
mix spec_lint.baseline                        write .spec_lint_baseline.json
```

`mix spec_lint` compiles the project first. Its options are parsed before
compiling, so an invalid option fails without side effects. With
`--format json` and no `--output`, compiler progress and the summary line
go to standard error, so standard output is only the JSON report.

| Option | Meaning |
| --- | --- |
| `--ci` | Gate findings: exit 1 on new gated findings or coverage violations. |
| `--profile soundness\|review` | Evidence policy (default `review`). |
| `--analysis signatures\|bodies` | Analysis backend (default `signatures`). No supported build has the body backend, so `bodies` exits 2 with a capability message. |
| `--warnings-as-errors` | Gate every reported finding, including report-only ones. Works locally too. `SL008` keeps following the coverage policy. |
| `--format console\|json` | Report format (default `console`). |
| `--output PATH` | Write the report to `PATH` (written atomically). |
| `--baseline PATH` | Baseline file (default `.spec_lint_baseline.json`, which may be missing). An explicit path, here or as `baseline:` in `.spec_lint.exs`, must exist: a missing one exits 2. |
| `--config PATH` | Configuration file (default `.spec_lint.exs`). |
| `--module Mod` | Analyse only this module. Repeatable. Makes the run partial. |
| `--app app` | Analyse only this umbrella child. Repeatable. Makes the run partial. |
| `--explain Mod.fun/arity` | Explain one function. |
| `--rules ID,...` | Run only these rules (IDs or names). Enables rules that are off by default. |
| `--except ID,...` | Do not run these rules. Coverage is still checked when `SL008` is left out. |
| `--require-static-return` | Treat structured evidence supported only by gradual clause returns as `possible_gradual`. |
| `--[no-]clause-local-qualification` | On by default (Close-phase decision, 2026-09-29): an `SL001` clause conflict gates when its clause's whole domain is inside the spec's argument lower bounds, instead of requiring the whole slice to be free of arrow losses. `--no-clause-local-qualification` restores the slice-wide arrow prerequisites. Also accepted by `mix spec_lint.baseline`: write the baseline under the setting CI uses, because the baseline records gate states. See `bench/corpus/clause_local_qualification.md`. |

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | Accepted. Without `--ci` or `--warnings-as-errors`, findings never fail the run. |
| 1 | New gated findings, or a coverage violation. |
| 2 | Invalid options or configuration (including a configuration file that raises, throws or exits, an invalid baseline file, and an explicitly given baseline path that does not exist), compilation failure, a missing build directory (ebin) for an owned application or one that lost BEAM files its build lists, unreadable module inventory for an owned Mix app, corrupt BEAM files or a filename/module mismatch, BEAM files recorded as produced by another compiler build or changed since (and a forced recompilation that could not run), dependencies compiled by another compiler line, unsupported compiler or checker chunk (in CI) or backend, a filter that matches nothing, or an incomplete run (an internal failure while analysing a module). |

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
- no overlapping spec clauses (an overload that cannot be translated counts
  as possibly overlapping, unless the arguments that can be translated
  show it disjoint);
- no function type in the return, and no function-type argument that
  translated inexactly (`arrow_polarity`), for a whole-slice conflict;
- for a per-clause conflict, instead of those two: the clause's whole
  domain is inside the spec's argument lower bounds
  (`clause_contained_in_lo`), so an arrow elsewhere in the slice does not
  block it (`clause_local_qualification`, the default);
- for a per-clause conflict, the clause is reachable as far as the compiler
  can tell: it is not covered by the clauses before it, and the compiler's
  own type checker, re-run over the function's debug info, reports no
  pattern or guard diagnostic in the function (a guard that never
  succeeds, a redundant clause). Guarded source clauses also need the
  bounded witnesses described below; this still does not prove normal return.

A per-clause finding names the stored signature clause (`clause #k`),
which the compiler may have merged with others or renumbered by dropping
clauses that always raise; the reported line is the function's first line.
Its details also name the source clause and its line (`source clause: #1,
line 41`) when the compiler's own clause grouping determines it: the
function has one clause, or as many stored as source clauses (every clause
conflict on the fifteen benchmark corpora is such a function). Otherwise
they say the source clause is not determined. JSON carries the same in
`data.source_clause` and `data.clause_mapping` (`single`, `identity` or
`ambiguous`). The mapping changes neither gating nor fingerprints: a
pattern or guard diagnostic anywhere in the function still blocks every
clause conflict of it.

Per-clause conflicts additionally require a bounded witness for each
guarded source clause in the function, accounting for earlier clauses. Unsupported
guards or unsuccessful search leave the finding reported but non-gating,
with `guard_feasibility: "unproven"` in JSON. This checks guard feasibility;
it does not execute target functions or prove that a function returns.
A required compiler re-check failure is different: the run is incomplete
and CI exits 2, even with a baseline or `--no-clause-local-qualification`.

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
  # baseline: ".spec_lint_baseline.json",  # when set, the file must exist
  rules: [
    possible_missing_return: :warning,
    possible_missing_input: :off,
    return_can_be_narrower: :off
  ],
  coverage: [fail_on_regression: true, floor: 0],
  exclude: ["lib/generated/**"],
  expand_opaque: false,
  require_static_return: false,
  clause_local_qualification: true,
  warnings_as_errors: false
]
```

- **`baseline`** is the baseline file. When it is set here (or with
  `--baseline`) the file must exist, so a mistyped path cannot silently
  turn regression detection off; leave it out to use the default path,
  which may be missing until `mix spec_lint.baseline` creates it.
- **`rules`** are keyed by name or ID (`SL002: :info`). A value is a
  severity (`:error`, `:warning`, `:info`, `:hint`) or `:off`.
- **`exclude`** globs match source paths relative to the project root.
  Excluded modules are counted in the ledger.
- **`coverage: [floor: n]`** fails CI when fewer than `n` spec slices are
  compared. A partial run (`--module`, `--app`) does not check the floor.
- **`coverage: [fail_on_regression: false]`** reports coverage regressions
  without failing on them. A slice that was never compared still needs an
  inventory acknowledgement.
- **`expand_opaque: true`** expands other modules' opaque types
  structurally. It is shown in the report header, in each finding's
  translation (`translation exact (opaque expanded)`), in the ledger and
  in the JSON `config`.
- **`clause_local_qualification`** (default `true`) qualifies an `SL001`
  clause conflict by its own clause: the clause's whole domain must be
  inside the spec's argument lower bounds, and an arrow elsewhere in the
  slice no longer blocks it. It is shown in the JSON `config`; each clause
  conflict lists `clause_contained_in_lo` among its prerequisites and keeps
  the superseded arrow prerequisites in `data`. `false` restores the
  slice-wide arrow prerequisites.
- Command-line options override the file.

## Baseline

```
mix spec_lint.baseline
```

This writes `.spec_lint_baseline.json`. The file has two parts:

- every reported finding, with a structural fingerprint;
- an inventory of every analysed spec slice.

Review the file and commit it. You can add a `reason`, an `owner` and an
`expires` date (`"2026-12-31"`) to each finding. `expires` must be `null` or
a `YYYY-MM-DD` date; any other value makes the baseline invalid (exit 2).
When you regenerate the file, those values are kept for entries that still
match, and the entries of rules turned `:off` in the configuration are kept.
So are the findings of slices or modules that cannot be analysed right now
(unsupported, unavailable, spec removed), and the compared slices of a
module that is unavailable as a whole: regenerating while debug info is
off, or after a compiler change that makes slices unavailable, does not
drop acknowledgements that come back with the analysis. A kept entry
written by another compiler adapter is marked
`"pending_reconciliation": true` and keeps its adapter: it acknowledges
nothing until the rule runs again and the file is regenerated (or until it
is regenerated under its own adapter again). `mix spec_lint.baseline`
rejects `--module`, `--app`, `--rules` and `--except`, and refuses to
overwrite an output file that is not a valid baseline. With `--output
PATH` it reads the previous baseline from `PATH`, and the run compares
against that same file.

- **Suppression.** A finding whose fingerprint is in the baseline does not
  fail CI. An entry past its `expires` date counts as new. Each entry
  records which gating prerequisites were blocked when it was written
  (`"blocked"`): an `SL001` or `SL003` finding acknowledged while it was
  report-only (for example blocked by an overlapping overload) counts as
  new once its prerequisites are met and it gates, and the report lists it
  under `gate_changed`.
- **What the fingerprint hashes.** It covers the rule, the MFA, the slice
  and clause index, the translated types of the spec slice (after named
  types are expanded), the translation losses by kind and structural
  position, and the inferred clauses the finding rests on. It survives line
  changes, reordering other functions, recompilation, renaming a type alias
  or a type variable, and reordering a union. It changes when what the spec
  means, its clause order or the inferred signature changes.
- **Coverage.** Every `unsupported` or `unavailable` slice, and every
  module without debug info, must be acknowledged in the inventory.
  Otherwise CI exits 1. A slice that the inventory lists as compared and
  that can no longer be analysed is a regression. Removing a `@spec` while
  the function stays exported is one too: the slice is reported as
  `unanalysed` (`spec_removed`) until the baseline is regenerated, which
  records the acknowledgement. So is removing one overload of a
  multi-clause spec, or merging overloads into fewer clauses
  (`spec_clause_removed`, for the missing slice indexes; slices are
  numbered by position, so these are the last ones). Deleting the
  function, making it private, or deleting your override of a default
  injected by `use` (`GenServer`'s `handle_info/2`, `child_spec/1`) is not
  a regression.
- **Missing BEAM files.** An ebin that lost BEAM files (deleted by hand, or
  a partial `_build` cache restore) is not a smaller project: Mix does not
  rebuild them because its manifest says the build is up to date. When the
  compile manifest (or, without one, the `<app>.app` file) lists a module
  with no BEAM file, the run exits 2; recompile with
  `mix compile --force`.
- **Stale entries.** They are listed as warnings and never fail a run. A
  partial run (`--module`, `--app`) or an incomplete run never declares
  entries stale. Neither does analysis that did not happen: a finding of a
  rule that did not run, or of a slice or module that is now unsupported or
  unavailable, is not stale. An inventory entry listed as compared whose
  slice is gone altogether (the function or module was deleted or
  excluded) is stale: regenerate the baseline.
- **Checker chunk versions.** A module whose checker chunk was written by
  another checker version is a preflight failure: the run is incomplete,
  CI exits 2, and no inventory entry can acknowledge it. Recompile.
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
- baseline decisions, including stale entries, entries pending
  reconciliation after an adapter change, and entries that no longer
  acknowledge a finding because it gates now (`gate_changed`);
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
  mismatches and unknown, and the unknown ones by reason (`top_only`,
  `near_top`, `no_counted_component`, `other`);
- slices lost since the baseline (`lost_analysis`, by reason:
  `spec_removed`, `spec_clause_removed`, `spec_out_of_scope:<reason>`),
  counted apart from the slices found.

A project with no eligible specs succeeds and says so ("0 specs checked").
A missing build directory is different: it exits 2, because nothing was
discovered at all. So is a build directory missing BEAM files its build
lists.

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

Use the qualified Elixir/OTP toolchain above. The benchmark regression tests
also require Bash, Git, jq (with `walk`), gzip and `shasum` on PATH. These
are development requirements; the Mix lint task itself does not invoke them.

```
mix format --check-formatted
mix credo --strict
mix test          # includes the consumer integration test (test/integration)
mix dialyzer      # PLT in priv/plts, or SPEC_LINT_PLT_DIR (one per compiler)
```

Tests whose expectations legitimately differ between compiler lines are
tagged `adapter:` and run only under that adapter's compiler; run the
suite under each qualified compiler, each with its own `MIX_BUILD_PATH`.
The cross-compiler integration test needs a second qualified compiler and
is excluded (not passed) without one:

```
SPEC_LINT_OTHER_ELIXIR=/path/to/other/elixir/bin mix test --only cross_compiler
```

`bench/clause_mapping/` is the source-clause mapping experiment of
Milestone 4 (its `README.md` holds the report); it runs only under
`c24c235`.
