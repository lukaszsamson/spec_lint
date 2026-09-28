# SpecLint: a CI gate that validates `@spec`s against inferred types

Draft design, 2026-09-28. Author: Claude Fable 5.1, from an analysis of the
`ls-formal-verification` and `ls-typespec-tightening` branches in `~/elixir`.

## 1. Summary

`mix spec_lint` is a Credo-like Mix task that reads the compiled BEAM files of
the current project, translates every `@spec` into the compiler's set-theoretic
type lattice (`Module.Types.Descr`), compares each spec with the signature the
Elixir compiler inferred for the same function (the `ExCk` chunk), optionally
re-runs the type checker over function bodies with arguments assumed to be
spec-typed, and reports the disagreements as warnings. In CI it exits non-zero
when a new finding appears that is not acknowledged in a baseline file.

The tool exists on the tightening branch today as a single 1,300-line script
(`lib/elixir/scripts/compare_specs_and_signatures.exs`) that is hard-wired to
the Elixir standard library and depends on one patch to the compiler
(`Module.Types.warnings/7`). This document describes how to turn it into a
reusable Hex package.

## 2. What the two branches contain

### 2.1 `ls-typespec-tightening` (the direct ancestor of this tool)

One script, one exclusions file, one Makefile target and one compiler patch:

| Piece | Role |
| --- | --- |
| `SpecToDescr` module in the script | Translates Erlang abstract type AST (from `Code.Typespec.fetch_specs/1`) into `Descr` values with an `exact?` precision flag. Expands user and remote types recursively with a depth limit, substitutes `when` constraints, qualifies remote type arguments in the caller's namespace. |
| `Verdict` module | Slice-wise comparison per spec clause using `subtype?/2`, `disjoint?/2`, `empty?/1`. Applies the inferred signature to the spec argument types with a copy of the checker's own application rule (`Module.Types.Apply.apply_infer/2`). Verdicts: `equivalent`, `inference_wider`, `spec_wider_return`, `contradiction`, `mixed`, plus `untranslatable` and `no_signature`. Also probes each function with all-`dynamic()` arguments. |
| Body check | Re-runs `Module.Types.warnings/7` with each spec'd function's argument domain replaced by its translated spec (dynamic or static mode) and reports checker warnings plus the return inferred under that domain. Informational only. |
| `compare_specs_exclusions.txt` | Baseline of acknowledged findings, one `Module.function/arity` per line with comments. New findings fail, stale entries warn. |
| `make check_specs` and CI step | Runs the script over the six stdlib apps in the deterministic CI matrix entry, roughly 11 seconds. |
| `Module.Types.warnings/7` patch | Adds a `domains` callback to the checker entry point and returns `local_sigs`. This is the only piece that requires changing Elixir itself. |

The commit history records the design decisions that survived review, and each
one should carry over:

- Sound over-approximation is the invariant of the translator. Every inexact
  translation must widen the spec, never narrow it, so that a disjointness
  result on the approximation transfers to the real spec. Constructs that
  cannot be widened soundly throw `untranslatable`.
- Executable witnesses were removed. An early version sampled arguments and
  executed stdlib functions to break ties. It was cut for being too much
  surface for CI, and it upgraded no verdicts. The tool is purely static.
- `spec_wider_return` is auto-triaged. Specs are public contracts and are
  deliberately wider than the implementation. Those entries are kept as
  "tightening hints" rather than warnings. This cut the stdlib baseline from
  126 entries to 60.
- Untranslatable specs are gated. A spec the translator cannot handle is lost
  coverage, not a pass.
- `no_return()` versus a non-empty inferred return is routed to human review,
  not auto-passed and not called a contradiction, because inference
  over-approximates returns.
- Multi-clause specs in the body check use a per-position union of argument
  types, which admits combinations no single clause allows. Findings there are
  tagged so reviewers can discount them.
- Literal map types translate as closed maps because that is the Erlang
  typespec semantics.
- Protocol modules have no inferred signatures (inference is skipped because
  consolidation rewrites the dispatch). They are listed as uncovered.

Measured on the stdlib at the end of the branch: 60 acknowledged residue
entries, zero untranslatable specs, 30 uncovered protocol functions, 66 body
check warnings in dynamic mode (91 in static mode), and 825 functions whose
translation was inexact somewhere.

### 2.2 `ls-formal-verification`

A single commit adding about 25,000 lines of verification harnesses for the
type checker itself, plus seven design documents. Nothing on this branch
compares specs with inferred types, and it contains no typespec-to-`Descr`
translator. Its value for SpecLint is the trust machinery and a handful of
documented facts about the lattice. Relevant pieces:

| Script | What it is | Reuse for SpecLint |
| --- | --- | --- |
| `infer_soundness.exs` | Generates well-typed modules from a grammar, compiles them, decodes the `ExCk` chunk into `%{{f, a} => sig}`, and checks runtime witnesses against inferred domains and returns. | The `ExCk` decoder and the domain/return membership rules. Closest existing check of "is inference trustworthy". |
| `term_membership.exs` | `TermMember.member?/2`, a value-in-descr oracle returning `{:exact, bool}`, `{:weak, bool}` or `{:unverifiable, reason}` by walking the list, tuple and map BDDs. | Only if SpecLint ever validates doctest values against specs. Brittle across compiler versions. |
| `sig_conformance.exs` | Fuzzes the hand-written BIF signature table in `Module.Types.Apply` with sampled arguments; one finding per (kind, MFA). | The dedup and "unverifiable is fatal" counters. |
| `descr_printer.exs` | Oracle for `Descr.to_quoted/2`: reinterprets printed output as lower and upper bounds and compares with the original descr. Has a canary mode that must produce at least 20% disagreements when the oracle is corrupted. | Its interpretation of printer output: `dynamic()` as bounds, `not`/`and`/`or`, domain keys, `if_set`, struct collapse, open tuples. SpecLint messages print descrs, so the printer's known infidelities matter (below). |
| `verification_support.exs` | Result envelope: `schema`, `status` (`pass`, `expected_failure`, `failure`, `stale`, `harness_error`), integer coverage counters, runtime and provenance block, atomic JSON writes. | JSON output schema and status taxonomy. |
| `verification_runner.exs` | Orchestrator with per-case minimum coverage floors and maximum error budgets, isolated build, per-run token, drift detection. Its `validate/6` rejects a textual pass without structured coverage. | The floor/budget validation as a CI threshold check. |
| `checker_harness_regression.exs` | Runs the other harnesses under injected faults and requires them to go red. | Pattern for SpecLint's own mutation tests. |
| `descr_model.exs`, `descr_fun_model.exs`, `descr_fuzz.exs` | Ground-truth models and law-based fuzzers for the `Descr` algebra. | Not needed by the lint; they verify the lattice SpecLint depends on. |

Concepts from the documents that carry over directly:

- Fail closed. Exit zero and a textual "pass" are never enough on their own.
  Unverifiable, unsupported and untranslatable events are counted per reason
  and gated, never skipped silently. The branch records two past mistakes
  caused by silent skips.
- Expected failures are pinned by fingerprint, must have a non-zero count,
  and go stale (red) when they stop reproducing. There is no blanket
  exemption. Classification happens before any minimisation.
- Mutation canaries corrupt the oracle or input and assert the harness fails.
- Provenance: record Elixir and OTP versions, beam paths and md5s, and never
  regenerate a baseline automatically.

Facts about the lattice that SpecLint must respect (from
`FORMAL_VERIFICATION_CONTRACT.md` and `VERIFICATION_RESULTS.md`):

- Inferred signatures are `dynamic()`-wrapped over-approximations. Domains
  come only from patterns and guards; returns are what body calls propagate.
  Comparisons must use bounds (`upper_bound/1`, `lower_bound/1`) or gradual
  `subtype?/2`, never raw equality of descr terms.
- Gradual subtyping is on bounds: `subtype?(a, b)` holds when both the lower
  and upper bounds are included.
- The printer is not faithful. `fun(n)` and a function with `none()`
  arguments print the same; `dynamic(integer())` prints as `integer()`
  unless `skip_dynamic_for_indivisible: false` is passed; some list types
  cannot be rebuilt from their printed form. Never round-trip printed output
  as ground truth, and print with the honest option in diagnostics.
- Open algebra defects and checker false positives exist (a list tail
  projection, a map put projection, a gradual lower-bound collapse, equality
  narrowing warnings). Some spec-versus-inference disagreements will be
  compiler bugs, and the report must leave room for that classification.
- The map field encoding inside `Descr` changed once during the branch's
  life and broke scripts that touched it. Anything that reads raw descr
  internals must be version-gated.

## 3. Goals and non-goals

Goals:

1. Emit warnings for specs that are wrong, that miss possible return types,
   or that describe argument domains the function cannot handle.
2. Run as `mix spec_lint` on any Mix project, umbrella or single app, with a
   configuration file, a baseline file, and exit codes suitable for CI.
3. Be deterministic and purely static. Never execute project code.
4. Keep the sound over-approximation invariant so that `contradiction`
   findings are mechanically trustworthy.
5. Degrade gracefully across Elixir versions: the tool depends on
   `@moduledoc false` compiler modules and must detect and refuse mismatches
   rather than crash.

Non-goals:

- Replacing Dialyzer. SpecLint checks specs against the Elixir type system's
  view of the function, not against success typing.
- Inferring specs from scratch or rewriting specs automatically in v1.
  Suggested specs are printed as fix hints only.
- Checking private functions. They have no `@spec` requirement and no exported
  signature. Later versions can check `@spec` on `defp` through the body
  check path, which sees local signatures.

## 4. Architecture

```
mix spec_lint
  |
  v
SpecLint.Runner ----------------------------------------------.
  |  1. load config (.spec_lint.exs) and baseline               |
  |  2. enumerate modules from Mix.Project.compile_path()       |
  |     (plus umbrella children, minus ignored patterns)        |
  |  3. per module, in parallel:                                |
  |       SpecLint.Beam        read ExCk + debug_info + specs   |
  |       SpecLint.Translate   spec AST -> Descr (+ precision)  |
  |       SpecLint.Compare     verdicts, slices, probes         |
  |       SpecLint.BodyCheck   optional re-check with domains   |
  |  4. SpecLint.Checks.*      turn raw results into Issues     |
  |  5. SpecLint.Baseline      filter, detect new and stale     |
  '- 6. SpecLint.Format.*      text / json / github / sarif     '
                               exit status
```

### 4.1 `SpecLint.Beam` (input layer)

Reads each `.beam` under the compile path directly with `:beam_lib`, without
`Module.ParallelChecker` (a private GenServer with a lock protocol the tool
does not need). Per module it extracts:

- `ExCk` chunk: `term_to_binary({version, %{exports: [...], mode: ...}})`.
  Each export carries `sig: {:infer, domain, clauses} | :none`. The version
  is compared with `:elixir_erl.checker_version/0` of the running Elixir; a
  mismatch produces one "stale build" error for the run and the tool stops.
- `debug_info` chunk, decoded through the backend to `:elixir_v1`, giving
  `definitions`, `attributes` and `file`. Needed only for the body check and
  for line numbers.
- Specs, via `Code.Typespec.fetch_specs/1` and `fetch_types/1` from the same
  binary. Both read the `Dbgi` chunk, so `debug_info: true` is required.
  `mix compile --no-debug-info` or `strip_beams` in releases make the tool
  report "no debug info, cannot lint" per module.

Type expansion needs the type definitions of dependencies and OTP too, so
`fetch_types/1` is also called on remote modules resolved through
`:code.which/1`. A per-run `:ets` memo keyed by `{module, name, arity}` avoids
re-reading beams.

### 4.2 `SpecLint.Translate` (spec to lattice)

`SpecToDescr` lifted almost verbatim, with these changes:

- Return a struct `%{descr, exact?, lossy: [reason]}` rather than a tuple so
  reports can say *where* precision was lost (for example
  "`non_neg_integer()` widened to `integer()`").
- Make the recursion depth and the treatment of recursive user types
  configurable. The script cuts at depth 8 and maps recursive references to
  `term()`, which is sound but makes most recursive types inexact.
- Expose the translator as a public function so it can be unit tested against
  `Code.Typespec` round trips and fuzzed (see section 8).
- Treat `@opaque` types from other modules as `term()` marked inexact by
  default, with an option to expand them. Opacity is the main source of
  `mixed` verdicts in the stdlib baseline (`Enumerable.t()`, `Macro.t()`).
- Represent every translated type as a bounds pair `{lower, upper}` as the
  printer oracle on the verification branch does, so that `dynamic(t)` in a
  spec and `dynamic()`-wrapped inferred returns compare on the same footing.
- Borrow from the printer oracle the handling of struct types (fill fields
  from `__info__(:struct)` so `%Mod{}` is a closed map with known keys rather
  than an open map with only `__struct__`), and of `optional` map keys.

### 4.3 `SpecLint.Compare` (verdicts)

The `Verdict` module as-is. The one piece that copies compiler logic is
`checker_apply/2`, which mirrors `Module.Types.Apply.apply_infer/2` including
its `@max_clauses 16` cap. This must be kept in sync per Elixir version, so it
lives in a version-keyed adapter module (section 6).

### 4.4 `SpecLint.BodyCheck` (optional, needs compiler support)

Re-check function bodies with spec-derived argument domains. This is the most
valuable check for "spec narrower than what the code handles" and "clause can
never match a spec-conforming input", and it is the only part that needs a
change in Elixir: `Module.Types.warnings/7` with a `domains` callback. Two
paths:

1. Upstream the patch. It is small (28 lines), `@doc false`, and additive.
   SpecLint then enables the body check when
   `function_exported?(Module.Types, :warnings, 7)`.
2. Until then, run without it. All lattice checks (section 5, checks 1 to 5)
   work with only the `ExCk` chunk and specs.

The body check runs in a fresh `Module.ParallelChecker` started by the tool
(it is needed as the remote-signature cache for `Module.Types`). It must run
with `Code.compiler_options(infer_signatures: ...)` matching the project so
that dependency signatures resolve the same way as at compile time.

### 4.5 Checks (issue producers)

Each check is a module implementing a small behaviour, mirroring Credo's
check modules, so users can enable, disable and re-prioritise them in config:

```elixir
@callback run(SpecLint.Result.t(), opts :: keyword()) :: [SpecLint.Issue.t()]
@callback default_priority() :: :high | :normal | :low
@callback category() :: :contradiction | :coverage | :precision | :hint
```

An `Issue` carries `module, function, arity, file, line, check, priority,
message, spec_string, inferred_string, suggested_spec, details`.

## 5. The checks

Ordered from mechanically certain to advisory. Priorities decide the default
exit status (section 7).

| # | Check | Fires when | Default |
| --- | --- | --- | --- |
| 1 | `ReturnContradiction` | Spec return and inferred effective return are disjoint on some spec clause. Someone is definitely wrong. | high, fails |
| 2 | `DomainContradiction` | A spec argument position is disjoint from the union of inferred domains, or the checker's application rule rejects every spec-conforming call on a clause. | high, fails |
| 3 | `BodyContradiction` (needs body check) | Under the spec domain the body's inferred return is disjoint from the spec return. | high, fails |
| 4 | `UntranslatableSpec` | The translator cannot soundly widen a construct. Reports the construct. | normal, fails |
| 5 | `SpecMissesReturn` | Inferred return under the spec domain is wider than the spec return and the inferred value is not `dynamic()`-only noise. Reported as "spec may miss `X`". This is the `mixed` bucket with the incomparable and wider relations separated out. | normal, fails |
| 6 | `NoReturnSpec` | `no_return()` or `none()` spec but inference finds a non-empty return. | normal, fails |
| 7 | `UnreachableClause` (needs body check) | Checker warning emitted under the spec domain, such as a clause that cannot match spec-typed inputs. Tagged when the domain is a per-position union. | low, reports |
| 8 | `SpecTighteningHint` | Inference is strictly inside an exactly translated spec return. | low, off in CI |
| 9 | `MissingSpec` | Public function with an inferred signature and no `@spec`, printing the inferred one as a suggestion. Equivalent to Credo's `Readability.Specs` but with a fix hint. | low, off by default |
| 10 | `NoInferredSignature` | Spec'd function with no signature (protocols, `behaviour_info/1`, modules compiled with inference off). Coverage information. | info |

Every issue includes the exactness flags, the `dynamic()` probe relation and,
when the body check ran, the body relation, so reviewers do not need to re-run
anything to triage.

Types in messages are printed with `Descr.to_quoted/2` and
`skip_dynamic_for_indivisible: false`, so gradual returns show their
`dynamic(...)` wrapper. The printed strings are for humans only; the JSON
output carries them as well, but fingerprints and comparisons never depend on
printed output because the printer is known not to be faithful (section 2.2).

Message shape, following the compiler's own diagnostics:

```
lib/my_app/parser.ex:42: [spec_lint:SpecMissesReturn] MyApp.Parser.parse/1
    spec:     parse(binary()) :: {:ok, term()} | :error
    inferred: {:ok, term()} | :error | {:error, binary()}
    spec may miss: {:error, binary()}
    translation exact: yes    dynamic-args probe: wider_than_spec
```

## 6. Elixir version coupling

Everything the tool touches inside the compiler is `@moduledoc false`:
`Module.Types.Descr`, `Module.Types`, `Module.ParallelChecker`,
`:elixir_erl.checker_version/0`, the `ExCk` layout. The design accepts this
and isolates it:

- `SpecLint.Compiler` behaviour with one implementation per supported minor
  version (`SpecLint.Compiler.V1_21`, ...). It wraps `Descr` calls, the
  `apply_infer` mirror, the chunk decoder and the optional `warnings/7`
  bridge.
- At startup the tool checks `System.version/0` and the checker version in
  the first chunk it reads. Unsupported combinations exit with a clear
  message instead of a `FunctionClauseError` deep inside `Descr`.
- The test suite runs the lattice checks against fixture beams compiled by
  the current Elixir, and a CI matrix covers each supported version.

The long-term fix is to ask upstream for a stable subset: a public
`Code.fetch_signatures/1` (or similar) returning inferred clauses, and the
`domains` hook on `Module.Types.warnings`. Both requests are strengthened by
having a working external consumer.

## 7. Mix task, configuration, baseline and CI semantics

### 7.1 Task

```
mix spec_lint [options] [paths]
  --strict            exit non-zero on normal-priority issues too (default in CI)
  --all               show low-priority issues (hints, missing specs)
  --format text|json|github|sarif
  --baseline PATH     override baseline path (default .spec_lint_baseline.exs)
  --update-baseline   rewrite the baseline with the current findings
  --no-body-check     skip the checker re-run
  --body-domain dynamic|static
  --only CheckName,...   --except CheckName,...
  --module Mod,...    restrict to modules
  --app app,...       umbrella: restrict to children
  --explain MFA       print everything known about one function
```

The task depends on `compile` (`@requirements ["compile"]`), so it always
sees fresh beams. Like Credo it is not a compiler task and never runs on
`mix compile`; unlike Credo it needs compiled artifacts, so it cannot lint a
file the project does not build.

### 7.2 Configuration `.spec_lint.exs`

```elixir
%{
  checks: [
    {SpecLint.Checks.ReturnContradiction, []},
    {SpecLint.Checks.SpecMissesReturn, ignore_inexact: true},
    {SpecLint.Checks.MissingSpec, false},
    ...
  ],
  ignore: [~r"^MyApp\.Generated\."],
  expand_opaque: false,
  body_check: true,
  body_domain: :dynamic,
  strict: false
}
```

Inline suppression for a single function:

```elixir
@spec_lint ignore: [SpecLint.Checks.SpecMissesReturn], reason: "opaque contract"
@spec parse(binary()) :: {:ok, term()} | :error
```

Only persisted attributes reach the BEAM, so this requires
`Module.register_attribute(__MODULE__, :spec_lint, accumulate: true, persist: true)`,
which a `use SpecLint.Ignore` helper (or a compile-time `@after_compile`
hook) can inject. In return no source parsing is required: the tool reads the
attribute from `debug_info` and pairs it with the next `@spec` by line. This
is the Credo `# credo:disable-for-next-line` equivalent, but structured, so
the reason is preserved and stale suppressions can be reported. A comment
form `# spec_lint:ignore CheckName reason` parsed from source is the
fallback for projects that do not want a compile-time dependency.

### 7.3 Baseline

The exclusions file becomes `.spec_lint_baseline.exs`, an Elixir term rather
than a text list so that entries carry the check name and a fingerprint:

```elixir
%{
  version: 1,
  entries: [
    %{mfa: "MyApp.Parser.parse/1", check: "SpecMissesReturn",
      fingerprint: "sha256:...", reason: "error tuple is internal"},
  ]
}
```

The fingerprint hashes the spec strings and the inferred clause strings. If
either changes, the entry no longer matches and the finding is reported again
as new, which is what the tightening branch's history shows is needed: the
`++` signature improvement moved three functions from `inference_wider` to
`mixed` and the plain MFA list could not distinguish "already reviewed" from
"reviewed a different disagreement". Stale entries are warnings, and
`--update-baseline` drops them.

### 7.4 Exit status

| Condition | Exit |
| --- | --- |
| Any high-priority issue not in baseline | 1 |
| `--strict` and any normal-priority issue not in baseline | 1 |
| Stale build (`ExCk` version mismatch), unsupported Elixir | 2 |
| Otherwise, including stale baseline entries | 0 |

`--format github` prints `::warning file=..,line=..::` annotations. `sarif`
output lets GitHub code scanning show results inline.

## 8. Testing and trust

The tool makes claims of the form "this spec is wrong". A false positive
costs a developer time; a false negative is silent. The formal verification
branch built exactly the machinery for this and it should be reused rather
than reinvented (section 2.2):

- Translator unit tests: for every builtin typespec construct, a fixture
  module with a known spec, an expected `Descr`, and an expected exactness
  flag.
- Soundness canaries: fixture modules where the spec is deliberately wrong in
  a known direction. Each must produce exactly the expected check. Mutation
  tests flip the spec back and require the finding to disappear.
- Determinism test: two runs on the same beams produce byte-identical JSON.
- Stdlib regression: run the tool over Elixir's own `lib/*/ebin` and compare
  with the baseline from the tightening branch. Any drift is either a checker
  change or a SpecLint regression and is investigated before release.
- Fail-closed accounting, taken from the verification runner: every run
  reports integer counters (functions seen, spec'd, compared, untranslatable
  by reason, uncovered by reason, inexact translations). The test suite and
  the `--strict` CI mode enforce floors and budgets on these counters, so a
  translator regression that silently turns half the specs untranslatable
  cannot pass as "no findings".
- Mutation canaries, taken from the harness regression script: an
  environment variable makes the translator widen every spec to `term()`,
  and the suite asserts that the stdlib fixture then reports zero
  contradictions and a coverage floor violation. A second mutation flips
  `subtype?` arguments in the comparison adapter and must produce a burst of
  false contradictions on the fixture set.
- Result envelope: the JSON output uses the verification branch's envelope
  (schema version, status, counters, runtime block with Elixir and OTP
  versions and per-module beam md5) so a CI artifact is self-describing and
  two runs can be diffed.

## 9. Migration plan

1. Extract `SpecToDescr` and `Verdict` into `lib/spec_lint/translate.ex` and
   `compare.ex` with tests. Replace `Module.ParallelChecker.fetch_export/5`
   with direct `ExCk` reading. Result: lattice checks 1, 2, 4, 5, 6, 8, 9, 10
   work on any project with stock Elixir 1.21.
2. Add the Mix task, config, baseline with fingerprints, formatters.
3. Add the compiler adapter and version gate. Publish 0.1 to Hex.
4. Open the `Module.Types.warnings/7` PR upstream. Ship the body check
   (checks 3 and 7) behind feature detection.
5. Port the verification harness pieces (result envelope, coverage floors
   and budgets, mutation canaries, fingerprint-pinned expected failures) into
   the test suite and the `--strict` mode.
6. Dogfood on Elixir itself by replacing `make check_specs` with
   `mix spec_lint` over the stdlib ebin directories, keeping the 60-entry
   baseline as the first fingerprinted baseline.

## 10. Open questions

- How to handle `dynamic()`-wrapped inferred returns when deciding
  `SpecMissesReturn`. The script's `upper_bound/1` treats `dynamic(t)` as
  `t`, which is the right choice for warnings but means gradual code is held
  to the same standard as static code.
- Whether `mixed` should be split further. The stdlib baseline suggests three
  causes: opacity, translator approximation, and genuine spec width. Only
  the last one is actionable for a user.
- Behaviour callbacks: `@callback` specs could be checked against the
  inferred signatures of every implementation. Cheap to add once the
  pipeline exists.
- Umbrella and dependency scope: lint only the project apps by default,
  with `--include-deps` for auditing libraries, since most users cannot fix
  a dependency's spec.
