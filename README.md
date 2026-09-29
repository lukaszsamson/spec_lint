# SpecLint

SpecLint checks Dialyzer-style `@spec` declarations against the types the
Elixir compiler infers. It reads your compiled BEAM files, translates each
spec clause into the compiler's set-theoretic type lattice, and compares it
with the inferred signature the compiler stores in the `ExCk` chunk. It runs
no Dialyzer, needs no PLT, and does not start your application. Compilation
runs macros and may load target modules; compiler and type-printer operations
can execute `@on_load` callbacks and `__info__/1`. This is not a security
sandbox: run it only on code you trust.

The design, evidence model and measurements are in [`DESIGN.md`](DESIGN.md)
and [`EXPERIMENTS.md`](EXPERIMENTS.md).

**Status: experimental; current requalification pending.** The historical
release campaigns and their limits are in [`RELEASE.md`](RELEASE.md). The
current tree adds compiler gating and artifact-provenance checks; the
historical campaigns do not qualify those changes.

## Requirements

SpecLint reads compiler internals that change between Elixir releases and
development revisions, so each release supports specific compiler builds:

| SpecLint | Elixir | Source | Checker chunk | Adapter id | Status | Known compiler defects |
| --- | --- | --- | --- | --- | --- | --- |
| 0.1.0 | 1.21.0-dev, revision `648b2a9` | upstream `elixir-lang/elixir` | `elixir_checker_v10` | `1.21.0-dev+648b2a9` | diagnostic-only; historical compatibility audit (`bench/corpus/toolchain/audit-648b2a9.md`) | `for ... into:` with a collectable that may be a bitstring or a list narrows the body to `bitstring()` in the stored signature, which previously could make SpecLint gate a correct spec (audit row 19); current gates are disabled |
| 0.1.0 | 1.21.0-dev, revision `c24c235` | fork `lukaszsamson/elixir`, branch `ls-mixed-into` | `elixir_checker_v10` | `1.21.0-dev+c24c235` | CI candidate; current requalification pending | none known |
| 0.1.0 | 1.20.4 (revision `759443e`, the precompiled release) | upstream release `v1.20.4` | `elixir_checker_v8` | `1.20.4+759443e` | CI candidate; current requalification pending; historical audit (`bench/corpus/toolchain/audit-1.20.4.md`) | none known; Erlang `-nominal` types are left out by its `Code.Typespec` (a reference to one is an unresolved remote type) |
| | 1.19 and earlier, 1.20.0 to 1.20.3 | | | | **unsupported**: the task starts and refuses itself (checked on 1.19.4: exit 2 with `--ci`, see below) | |
| | other 1.20.x releases, other 1.21 builds | | | | **unsupported**: the same refusal (exit 2 in CI) | |

**Compiler-wide gating restriction:** upstream `648b2a9` is diagnostic-only.
Every finding has `gate: false`, and the run is `incomplete`, even if the
project does not contain a comprehension: the defective signature can affect
callers too. `--ci` and `--warnings-as-errors` exit 2; a local run exits 0 with
the incomplete report. A baseline cannot waive this restriction, and
`mix spec_lint.baseline` exits 2 without writing a baseline. Use `c24c235`
or 1.20.4 as CI candidates while current requalification is pending.

Historical campaigns ran on Erlang/OTP 28 (1.20.4 also passed preflight on OTP 29). SpecLint
picks the adapter for the running compiler from its version and checker
chunk version, and `bench/corpus/toolchain/build_elixir.sh` builds a
qualified upstream revision from a clean clone.

`mix.exs` declares `~> 1.20.4 or ~> 1.21-dev`, but Mix only prints a
warning when a *dependency's* Elixir requirement is not met ("the
dependency :spec_lint requires Elixir ..."), so on an unsupported compiler
the task still starts and refuses itself. On 1.19.4 (the one checked)
SpecLint's own compilation prints warnings about compiler functions that do
not exist, and then:

- `mix spec_lint --ci` reports "unsupported compiler", `Result:
  incomplete, exit 2`, and exits 2;
- `mix spec_lint` (no `--ci`) prints the same and exits 0: the run is
  `incomplete`, and nothing was checked;
- `mix spec_lint.baseline` exits 2 and writes nothing.

The same refusal applies to a compiler inside the declared range that is
not a qualified build (another 1.20.x release, another 1.21 development
revision). The revision alone does not qualify a build: preflight also
compares the code of the checker modules with the qualified build's (a
patched checkout of a qualified commit is unsupported) and probes every
compiler internal SpecLint uses; a missing or changed one is reported the
same way. A CI job must therefore use `--ci` and a pinned compiler from
the table: without `--ci`, an unsupported compiler looks like a pass.

The two 1.21 revisions are both `1.21.0-dev`, so Mix does not recompile a
project when you switch between them. `mix spec_lint` records which build
produced the project's BEAM files (`_build/ENV/lib/APP/.mix/spec_lint.build`)
and recompiles with `--force` when that is not the running build,
including the first time it runs on a project it did not compile itself.
Build-record version 2 records each BEAM only when a compiler event attests
that the module was produced in this VM, or the unchanged artifact already
has verified provenance. Version 1 records require a rebuild. An app-wide
successful compile cannot verify orphan BEAMs: the task refuses unverified
artifacts with exit 2 and leaves them in place for explicit repair.
Only built-in Mix compiler pipelines are supported. A custom compiler can
overwrite an artifact after an Elixir compiler event, so nonstandard
compiler pipelines are refused with exit 2, including umbrella child
configurations. These checks detect stale artifacts in trusted projects;
they do not protect against malicious project code.
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
`mix spec_lint.baseline`. Keep one baseline per compiler you run in CI. In the historical campaigns on
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

This checkout has no configured publishing remote or verified Hex release.
Only built-in Mix compiler pipelines are currently supported; custom
compilers in a project or umbrella child cause exit 2. Install from a local
checkout of this repository for development and test:

```elixir
def deps do
  [
    {:spec_lint, path: "../spec_lint", only: [:dev, :test], runtime: false}
  ]
end
```

Adjust the path to your checkout. Path, local git and umbrella installation
are exercised by `test/integration/release/`; those tests do not establish
publication on Hex or a public repository URL.

SpecLint's own development dependencies (Credo, Dialyxir) are not fetched
into your project. Then:

```
mix deps.get
mix spec_lint            # first run: compiles and checks; writes no baseline
```

The first run needs no baseline and no configuration. It compiles SpecLint
and your project, prints the report and exits 0 (or 1 with `--ci` when
there are gated findings); it never writes the baseline
(`Baseline: none (.spec_lint_baseline.json not found)`). A clean project on a CI candidate compiler
exits 0 in CI mode too; `648b2a9` always produces an incomplete run. The next step for a project with findings is the
[baseline workflow](#baseline).

An **umbrella** project declares the dependency in the umbrella root's
`deps` and runs the tasks from the root: one run analyses every child once,
paths in the report are relative to the root, and one baseline at the root
covers all of them (`--app child` narrows a run to one child and makes it
partial). The children do not need the dependency, and `mix spec_lint` from
inside a child that does not declare it is "task could not be found".

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
| 2 | Invalid options or configuration (including a configuration file that raises, throws or exits, an invalid baseline file, and an explicitly given baseline path that does not exist), compilation failure, a missing build directory (ebin) for an owned application or one that lost BEAM files its build lists, unreadable module inventory for an owned Mix app, corrupt BEAM files or a filename/module mismatch, BEAM files recorded as produced by another compiler build or changed since (and a forced recompilation that could not run), dependencies compiled by another compiler line, unsupported compiler or checker chunk (in CI) or backend, a filter that matches nothing, an incomplete run (an internal failure while analysing a module; the report is written and says `incomplete`), or an internal failure after the analysis or while rendering (no report is written). |

A run never leaves a report that could be read as complete when it did not
finish. With `--output`, a file already at that path is removed when the
run starts, and the report is written atomically (a temporary file renamed
over the path) at the end. Exit status 2 is only what a run that is still
alive reports: a VM killed from outside (a signal, a CI timeout, the
operating system's out-of-memory killer) exits with whatever status the
signal gives and writes nothing, so it cannot promise 2. **CI must treat a
missing report, or one whose `completion.status` is not `complete`, as a
failure**, whatever the exit status. `test/integration/resource_failure_test.exs`
covers the three cases: an analysis crash (exit 2, report `incomplete`), an
exception after the analysis (exit 2, no report) and a VM killed during
the analysis (no report).

## What a result means

**Scope.** SpecLint checks the `@spec` declarations of exported functions
of your compiled modules. A spec is in scope when it is explicit and its
function is public, whatever the function is called and whatever its
documentation says: **a spec on a function marked `@doc false` is checked
exactly like a documented one, and so is one on a constructor (`new/1`,
`new!/1`, `build/1`, `from_*`)**. SpecLint never infers intent from
`@doc false` or from names, and there is no rule that skips "internal" or
constructor-like functions. A spec you do not want checked is excluded
explicitly (`exclude:` in `.spec_lint.exs`) or acknowledged in the
baseline, and either is visible in review. Out of scope, and counted as
such in the ledger (`specs_out_of_scope`): specs of macros, protocol
dispatch functions, `behaviour_info/1`, generated definitions, private
functions, Erlang modules and excluded modules. A function without a
`@spec` is not checked at all: SpecLint does not write or require specs.

**No finding is not a proof.** Exit 0 with no findings means that for every
spec slice it compared, the compiler's inferred signature gave SpecLint no
reason to say that any normal return *would be* outside the spec, under the
gating rules below. It does not mean the spec is correct:

- **Unknown obligations.** Each compared spec slice yields one obligation.
  When the inferred signature is too wide to say anything (the compiler
  infers no narrower return than `term()` or `dynamic()`, as for an
  identity function or an untyped argument), the obligation is counted as
  `unknown` and produces no finding. `@spec id(atom()) :: atom()` on `def
  id(value), do: value` is such a spec: no finding, one unknown obligation
  (`top_only`). The ledger says how many, by reason (`top_only`,
  `near_top`, `no_counted_component`, `other`). Read "0 findings" together
  with the unknown count.
- **Omissions are mostly not detected.** Inference over-approximates and
  never proves that a return happens, and most real omissions
  found by hand sit in classes that do not gate (`EXPERIMENTS.md`). On the
  frozen evaluation (`bench/evaluation/INVENTORY.md`, version 2: 18
  omission families, each witnessed at runtime to return a value its spec
  leaves out for an input inside the spec's domain) the release reports
  gate **3**, report **8** without failing CI and are silent on **7**,
  identically under each of the three compilers (version 1, 17 families:
  3, 7 and 7). Over the 15 families where the returned value itself is
  undeclared: 2 gated, 8 reported, 5 silent. A clean run says nothing
  about the rest.
- **Findings are conditional.** A conflict says a return would be outside
  the spec if the function returns. `SL002` findings are informational.
  Several documented classes are deliberately reported without failing CI
  (overlapping overloads, function types, guards SpecLint cannot bound).
- **Unsupported and unavailable slices.** A spec that cannot be translated
  into the compiler's type lattice, or a module without debug info, is not
  checked. It is listed in the ledger, and `SL008` fails CI until the
  baseline acknowledges it.
- **The compiler's own defects.** The stored signatures are the compiler's.
  A defect there can make SpecLint gate a correct spec or miss a real one.
  The reproduced `for ... into:` defect on `648b2a9` now disables all of
  that compiler build’s gates, as documented above.

The unknown-obligation counts of the release measurement (the fifteen
benchmark corpora, default configuration; release campaign 1,
`bench/corpus/reports/release-1/`, confirmed unchanged by release campaign
2, see [`RELEASE.md`](RELEASE.md)):

| Run | Slices compared | Established | Compatible after approximation | Possible mismatch | Whole-slice conflict | **Unknown** | `top_only` | `near_top` | `no_counted_component` | `other` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1.21 `c24c235` | 4,204 | 841 | 193 | 57 | 0 | **3,113** | 2,220 | 54 | 839 | 0 |
| 1.21 `648b2a9` | 4,204 | 841 | 193 | 57 | 0 | **3,113** | 2,220 | 54 | 839 | 0 |
| 1.20.4 | 4,170 | 830 | 186 | 59 | 0 | **3,095** | 2,210 | 51 | 834 | 0 |

Unknown obligations are **74.0%** of the compared slices under 1.21
(3,113 of 4,204) and **74.2%** under 1.20.4 (3,095 of 4,170). The
"whole-slice conflict" obligation counts slices whose entire inferred
return is disjoint from the spec; there are none. The gates are clause
conflicts (one inferred clause outside the spec) inside slices counted
as possible mismatches. Gated findings on those corpora: **9** per
compiler (27 in all, on 3 functions: `Oban.Registry.via/3`,
`Ash.Page.page_opts/1` and the seven clauses of
`Absinthe.Blueprint.Input.parse/1`), of which **0** were false positives
after independent refutation (each gate survived two attempts,
`bench/corpus/reports/release-1/refutation.json`). The seven Absinthe
gates are one omission, a struct field left at its default `nil` outside
its declared type; they gate like any other clause conflict.

**These figures are historical release-1/release-2 measurements.** They
precede the current compiler gating and provenance changes; `648b2a9` now
has no gates and cannot certify CI. Current requalification is pending.

**Exit statuses in CI.** Exit 1 is a verdict about your code (a new gated
finding or a coverage violation): fix the spec or acknowledge the finding
in the baseline. Exit 2 is SpecLint declining to give a verdict (the build
is unusable, the compiler or baseline is not one it supports, the run did
not finish): fix the environment, and do not acknowledge it. Status 2 is
what a run that is still alive reports; a killed VM cannot promise it, so
CI also checks that the report exists and says `complete` (see "Exit
status").

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

Compiler-wide qualification comes first: `648b2a9` cannot gate any rule,
including SL008 or a finding selected by `--warnings-as-errors`. On a CI
candidate compiler, a gated finding still has to meet its prerequisites to
fail the build:

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
conflict on the fifteen historical benchmark corpora is such a function). Otherwise
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

The workflow (each step is exercised by `test/integration/release/`):

1. **First run**, no baseline: `mix spec_lint`. Fix what is wrong; for the
   findings you accept for now, go on.
2. **Write the baseline** once: `mix spec_lint.baseline`. It writes
   `.spec_lint_baseline.json` and prints `N finding(s), M inventory
   entries`. The run must be complete (exit 2 otherwise, and nothing is
   written). Write it with the compiler, profile and configuration CI uses:
   the file records the adapter and each finding's gate state.
3. **Review and commit it.** Add a `reason`, an `owner` and an `expires`
   date to entries worth tracking.
4. **Gate in CI**: `mix spec_lint --ci`. Acknowledged findings pass; a new
   gated finding, an expired entry, an unacknowledged unavailable slice or
   a coverage regression exits 1. `mix spec_lint` never modifies the
   baseline.
5. **Change** the project and the baseline follows it deliberately. A
   fixed finding leaves a stale entry (a warning, exit 0); a removed spec,
   a deleted module or a new acknowledgement needs regeneration; every
   regeneration is a diff to review. Reasons, owners and expiry dates are
   kept for entries whose fingerprint still matches.
6. **Upgrade** the compiler or SpecLint: see [Upgrading](#upgrading).

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

## Upgrading

A baseline is tied to the compiler that produced it and to the SpecLint
revision that fingerprinted it. `.spec_lint_baseline.json` records the
format (`"version": 1`) and the compiler adapter (`"adapter"`, and the same
on each finding), but not the SpecLint version: after a SpecLint upgrade
the run itself tells you whether the file still applies.

### Upgrading the compiler

This covers a move between 1.20.4 and 1.21, between the two compatible 1.21
revisions (although `648b2a9` now refuses baseline writes), and to any future qualified build. A compiler outside the
[matrix](#requirements) is refused, not upgraded to.

1. Switch the toolchain and run `mix spec_lint --ci`. Nothing else needs
   cleaning: Mix recompiles across the 1.20/1.21 line, and SpecLint
   recompiles (`spec_lint: recompiling ... with <adapter>`) when the build
   was made by another compiler build. BEAM files of the other line are
   never analysed.
2. The old baseline is **not applied** (`Baseline: ... NOT applied: written
   by adapter ...`) and CI exits 2 asking you to review and regenerate it
   (outside CI: a note, exit 0). The file is not touched.
3. Regenerate under the new compiler: `mix spec_lint.baseline`. Review the
   diff: findings can appear or disappear with a compiler change, which is
   the point of the review. Entries whose fingerprint is unchanged keep
   their `reason`, `owner` and `expires`. On the benchmark corpora the two
   1.21 revisions give the same fingerprints; between 1.20.4 and 1.21 they
   differ wherever a map or struct type is involved, and such an entry
   starts without its reason: copy `reason`, `owner` and `expires` over by
   function from the old file.
4. Commit the file, then `mix spec_lint --ci` exits 0.

Entries kept from the old file because their rule did not run (a rule
turned `:off`) are marked `"pending_reconciliation": true`, acknowledge
nothing and are listed in the report; turn the rule back on and regenerate.

**Running two compilers in CI.** One baseline file cannot serve both:
whichever compiler did not write it exits 2. Keep one file per compiler and
select it on the command line:

```
mix spec_lint.baseline --output baselines/1.20.4.json    # under 1.20.4
mix spec_lint --ci --baseline baselines/1.20.4.json
mix spec_lint.baseline --output baselines/1.21.json      # under 1.21
mix spec_lint --ci --baseline baselines/1.21.json
```

An explicit `--baseline` path must exist.

### Upgrading SpecLint

Update the dependency (`mix deps.update spec_lint`, or pull the path or
git dependency; a path dependency changed outside Mix needs `mix
deps.compile spec_lint --force`), then run `mix spec_lint --ci` with the old
baseline:

| Result | Meaning | Do |
| --- | --- | --- |
| exit 0, findings `baselined` | The file applies as written. An entry without `blocked` (written by an earlier version) acknowledges as before. | Optionally regenerate to record the current gate state; the diff should be empty apart from new fields. |
| exit 1: `N new`, `N stale` | The fingerprints changed (the new version hashes the evidence differently or translates a type differently). Nothing was acknowledged. | Check that the new findings are the stale entries' functions, regenerate, then copy `reason`, `owner` and `expires` over by function: reasons are matched by fingerprint. |
| exit 1: `gate_changed` | An entry was written while a gating prerequisite was blocked and the finding gates now. | Fix the spec, or regenerate to acknowledge it with its current gate state. |
| exit 2: `unsupported baseline version N` | The file is in a newer format than this SpecLint reads. Both tasks refuse it and never overwrite it. | Upgrade SpecLint, or move the file aside and regenerate. |

Regenerating is always `mix spec_lint.baseline` under the compiler and
configuration CI uses.

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
Two environment variables name other compilers, and the tests that need
them do not pass without them:

- `SPEC_LINT_OTHER_ELIXIR`, the bin directory of a second qualified
  compiler (1.20.4 under 1.21, a 1.21 build under 1.20.4): the
  cross-compiler tests (tag `cross_compiler`, including the compiler
  upgrade tests of `test/integration/release/`) are **excluded** without it;
- `SPEC_LINT_UNSUPPORTED_ELIXIR`, the bin directory of a compiler outside
  the support range (1.19.4 was used): the test behind the 1.19 refusal
  described under [Requirements](#requirements)
  (`test/integration/release/incomplete_test.exs`) is **skipped** without
  it.

A full run, as the release qualification does it (under each qualified
compiler, naming another one):

```
SPEC_LINT_OTHER_ELIXIR=/path/to/other/elixir/bin \
SPEC_LINT_UNSUPPORTED_ELIXIR=/path/to/elixir-1.19/bin \
MIX_BUILD_PATH=_build/$COMPILER mix test
```

`test/integration/release/` drives the public Mix tasks on consumer
projects in the system temporary directory: installation as a path and a
git dependency and in an umbrella, the baseline workflow, compiler and
SpecLint upgrades, and incomplete builds (about 90 s).

`bench/clause_mapping/` is the source-clause mapping experiment of
Milestone 4 (its `README.md` holds the report); it runs only under
`c24c235`.
