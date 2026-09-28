# SpecLint: draft design for checking typespecs against inferred types

Draft, 2026-09-28. This proposes a standalone Mix dependency with a `mix spec_lint` task and a deterministic CI gate. It checks existing Dialyzer-style `@spec` declarations against Elixir's inferred types; it does not run Dialyzer or require a PLT.

The recommendation is to extract the static comparison pipeline from `ls-typespec-tightening`, fix its evidence and coverage model, and use the `ls-formal-verification` harnesses to qualify the linter's compiler adapters. Ship signature comparison first. Add spec-domain body checking as a separately advertised capability, initially requiring a pinned compiler with the existing hook. Do not make a compiler fork a permanent requirement for the basic Mix task.

The crucial product distinction is between **a spec conflict**, **a possible missing type**, and **insufficient information**. An inferred return wider than a spec is valuable lint evidence, but does not by itself prove the spec wrong. Conversely, filtering every such result out would miss an important part of this tool's purpose.

## 1. Sources and scope of this review

Inspected local Git objects in `~/elixir`, without switching branches or modifying that checkout:

| Source | Revision inspected | Relevant artifacts |
| --- | --- | --- |
| `ls-formal-verification` | `275dfc58c6a47f692b653947ff88d4af1a863d8d` | Verification runner, contracts, finite models, checker/signature fuzzers, shared membership oracle, recorded results |
| `ls-typespec-tightening` | `7190b0285dc99f8d91b65dcc8d19527a1128a59d` | Spec comparison script, exclusions, `Module.Types.warnings/7`, Makefile and CI integration |
| `origin/ls-typespec-tightening` | Same revision as the local branch | `origin` points to `lukaszsamson/elixir`, matching the requested fork |
| Current `spec_lint` project | Local scaffold | App name `:spec_lint`, version `0.1.0`, Elixir requirement `~> 1.21-dev`; no linter implementation yet |

Primary source references below use these revision labels:

- **[T]** `lib/elixir/scripts/compare_specs_and_signatures.exs` on the tightening revision, especially `SpecToDescr`, `Verdict`, `Main.analyze_module/3`, `Main.check_bodies/4`, and `Main.render/2`.
- **[H]** `lib/elixir/lib/module/types.ex` on that revision: `infer/7`, `warnings/6`, new `warnings/7`, and domain selection.
- **[A]** `lib/elixir/lib/module/types/apply.ex`: `apply_infer/2`, `apply_clauses/6`, `@max_clauses`; `module/parallel_checker.ex`: checker chunk loading and fallback.
- **[V]** `FORMAL_VERIFICATION_RUNNER.md`, `VERIFICATION_RESULTS.md`, `FORMAL_VERIFICATION_CHECKER_CONTRACTS.md`, and `lib/elixir/scripts/verification_runner.exs` on the verification revision.
- **[O]** `infer_soundness.exs`, `sig_conformance.exs`, `term_membership.exs`, and the `descr_*` harness family on the verification revision.

Also read the untracked `SPEC_DOMAIN_BODY_CHECK_REPORT.md` and `SPEC_TIGHTENING_CANDIDATES.txt`. They provide useful historical triage, but their counts and conclusions are not fresh results for either branch tip. This review did not rebuild the branches or rerun the harnesses. No performance measurements or newly reproduced bug claims are implied.

## 2. What the branches already provide

### The comparison branch is the product prototype

[T] already performs most of the essential static pipeline:

1. Enumerates modules in six Elixir distribution applications and selects exported functions with specs.
2. Reads Erlang typespec AST using `Code.Typespec`, expands named types and constraints, and translates to `Module.Types.Descr`.
3. Retrieves inferred signatures through `Module.ParallelChecker`, normally from the versioned `ExCk` BEAM chunk.
4. Applies the inferred signature separately to each translated spec clause, using a copy of the compiler's inferred-application rule.
5. Compares return sets semantically, with translation precision flags, rather than comparing rendered type strings.
6. Produces human, JSON, or review-prompt output. `make check_specs` gates new residue and untranslatable specs using an MFA exclusions file; the CI workflow invokes it in the deterministic matrix job.
7. Optionally rechecks debug-info definitions with spec-derived argument domains using the added compiler hook.

Retain semantic comparisons, clause-level results, remote-type argument qualification, explicit translation failures, and the separation of tightening suggestions from conflicts. Keep review-prompt output optional; no LLM is needed for the CI decision.

Important limitations to change:

| Current behavior | Consequence for a general-purpose linter |
| --- | --- |
| `:inference_wider` is automatically triaged away | A missing return alternative can disappear with ordinary inference imprecision |
| `:equivalent` compares returns after checking only complete domain disagreement | The name implies stronger contract equivalence than was established |
| Missing specs become `[]` when extraction returns `:error` | Lost metadata can look like a module with no specs |
| `:no_signature` is counted among auto-triaged entries | Missing analysis is not part of the strict exclusions gate |
| Only exported ordinary functions are selected | Private functions and macros are not covered by this path |
| One exactness boolean per argument list and return | Cannot identify which nested approximation caused a mismatch |
| All overload domains are unioned by position for body checking | Invents argument combinations and loses argument/return correlation |
| All specified functions receive their own spec domains in the same body-check run | Local calls can be analyzed under assumptions different from the actual caller's flow |
| Exclusions identify only `Module.function/arity` | A newly introduced problem in an already excluded function can be hidden |
| Missing debug info silently disables body checking | A requested stronger analysis can silently degrade |
| Private compiler APIs and a copied 16-clause cutoff | Compiler changes can silently change the comparison's meaning |

### The verification branch provides assurance infrastructure

[V, O] are not an application spec linter. They test the type algebra, checker transfer functions, inferred signatures, and hardcoded signatures using bounded models, generated programs, and concrete runtime witnesses.

Reuse their approach to deterministic seeds, minimized reproducers, independent membership checks, mutation canaries, explicit coverage counters, timeouts, source/BEAM provenance, and narrow acknowledgements with stale detection. Their concrete execution belongs in SpecLint's own test suite over controlled fixtures, not in a consumer's normal lint run.

The recorded full verification run is explicitly not a proof: 29 cases, 19 passes, 6 expected failures, and 4 failures, aggregate exit 1. Its recorded compiler inputs precede the delivery commit. It identifies remaining algebra/checker issues and even retracts an earlier inference finding caused by an oracle bug. Therefore neither compiler inference nor a homegrown oracle should be described as unquestionable ground truth.

## 3. Define the contract before defining warnings

For each declared spec alternative, retain an argument **tuple domain** `D` and return set `S`. The intended return obligation is:

```text
For calls with arguments in D, every normal return belongs to S.
```

This is a partial-correctness obligation. A typespec alone does not promise termination or that every in-domain call succeeds without raising. An implementation may intentionally handle inputs outside its documented contract. A declared return union may intentionally reserve alternatives that the current implementation never produces.

Let `U(D)` be a sound upper approximation of normal returns under `D`. If translation approximates the spec, represent bounds `S_lower ⊆ S ⊆ S_upper`. Initially many unsupported refinements will have only a useful upper bound.

| Relation/evidence | Permitted conclusion |
| --- | --- |
| `U(D) ⊆ S_lower` | Return obligation established within the supported model |
| Exact `S`, with `U(D) ⊆ S` | Same; if strictly contained, optional tightening hint |
| `U(D) ⊆ S_upper`, but translation is inexact | Compatible at available precision; not full validation |
| Nonempty `U(D) − S_upper` | Possible undeclared return; abstract possibilities are not reachability evidence |
| Nonempty `U(D)` disjoint from `S_upper` | Strong return conflict: any normal return is outside the spec; does not prove a normal return occurs |
| `U(D) = none()` | No normal returns predicted; not automatically a bad spec |
| Spec is `no_return()` but `U(D)` is nonempty | Possible unexpected return; inference alone does not establish returnability |
| A concrete, valid in-domain execution returns outside `S` | Witnessed violation; suitable for controlled tests, not automatic execution of user functions |

Likewise, inferred input domains are approximations. A nonempty difference between two domain approximations does not prove that a concrete input succeeds or fails. Report input coverage discrepancies with their evidence, and reserve stronger language for justified conclusions. In particular, “the checker rejects this spec domain” and “a call always crashes” are different claims.

Do not use gradual `lower_bound/1` as a set of outputs known to be attained. A static type component is not a reachability certificate. Do not generate a concrete-looking example from a type difference and label it a reproducer unless its feasibility has actually been established.

### Overloads and defensive clauses

Keep `(atom(), atom())` and `(integer(), integer())` as two domains. Never turn them into `(atom() | integer(), atom() | integer())` for a gating check. Preserve the associated returns as well.

For disjoint overloads, compare each slice independently. For overlapping overloads, retain an explicit overlap status and validate the intended typespec semantics before enabling hard diagnostics that depend on that overlap. Do not silently union all returns or assume a particular intersection interpretation. Initially downgrade such cases to review and expose the limitation.

A function accepting `:ok | :error` may have a defensive catch-all that returns `nil` for other inputs. If its spec only permits those two atoms, the catch-all's `nil` is not necessarily a missing return type. A global dynamic-argument probe remains informational; domain-specialized inference should decide the in-contract question where available.

## 4. Proposed diagnostics and gating policy

Use stable rule IDs, an evidence classification, and severity as independent fields. Avoid one combined verdict hiding several findings.

| Rule | Meaning | Initial default |
| --- | --- | --- |
| `SL001 return_conflict` | Nonempty inferred return upper bound and spec upper bound are disjoint | Warning; CI gate |
| `SL002 possible_missing_return` | Inference includes alternatives outside the declared return | Warning for useful bounded evidence; otherwise inconclusive detail |
| `SL003 spec_domain_rejected` | Compiler application rejects an inhabited declared domain/slice | Warning; gate only where translation and adapter obligations support it |
| `SL004 possible_missing_input` | Implementation appears to support input shapes omitted from spec | Opt-in API completeness hint |
| `SL005 return_can_be_narrower` | Inferred return fits strictly inside an exact declared return | Opt-in tightening hint |
| `SL006 possible_unexpected_return` | `no_return()` declaration with nonempty inferred return | Review warning; never described as proven returnability |
| `SL007 spec_domain_body_warning` | Additional checker diagnostic under the spec assumption | Informational initially |
| `SL008 analysis_unavailable` | Missing/unsupported metadata, translation, or inference | Coverage diagnostic, subject to coverage gate |

Suggested evidence classes: `conflict`, `bounded_possible`, `unknown`, `hint`, and later `witnessed`. These are explanations of evidence, not probabilities.

For `SL002`, distinguish a bounded alternative such as `{:error, :missing}` from an unconstrained `dynamic()`/`term()` component. A known tagged outer shape can be useful even if a payload is unknown. Track unknown dependencies separately; never fabricate precision by deleting a dynamic component. Suppress top-only noise from normal text output, but record it as inconclusive and count it in coverage.

For example:

```elixir
@spec lookup(:present | :missing) :: {:ok, integer()}
def lookup(:present), do: {:ok, 1}
def lookup(:missing), do: {:error, :missing}
```

Expected warning:

```text
lib/store.ex:12: SL002 possible_missing_return Store.lookup/1
  spec return:     {:ok, integer()}
  inferred extra:  {:error, :missing}
  input slice:     :present | :missing
  evidence: bounded inferred alternative; signature backend
  Review whether the spec should include this alternative.
```

The linter can reliably emit a warning here without claiming that set subtraction alone proves execution of the second clause. Later path evidence can strengthen the diagnostic.

Two CI profiles make the tradeoff explicit:

- **`soundness`**: gate new supported conflicts and coverage regressions; show possible mismatches for review.
- **`review`**: additionally gate new bounded possible missing returns and possible unexpected returns. Recommended for the requested “specs must stay accurate” workflow after initial triage.

`mix spec_lint` displays warnings locally without a findings-based failure by default. `--ci` selects the `review` gate unless configured otherwise. `--warnings-as-errors` gates all enabled warning rules. Infrastructure/configuration failures always fail, regardless of profile. CI success means “no unacknowledged findings under this policy and no prohibited coverage loss,” not “all specs have been proved correct.”

## 5. Architecture and compiler integration

```text
Mix project / umbrella
  -> compile and discover owned BEAM files
  -> preflight compiler adapter and metadata
  -> extract specs, definitions, inferred signatures
  -> normalize specs with precision provenance
  -> compare each spec domain / optionally recheck bodies
  -> diagnostics + coverage ledger
  -> baseline/policy evaluation
  -> console / JSON / SARIF + exit status
```

Suggested modules:

| Component | Responsibility |
| --- | --- |
| `Mix.Tasks.SpecLint` | Options, project lifecycle, output and process exit |
| `SpecLint.Project` | Owned modules, umbrella children, source/BEAM mapping |
| `SpecLint.Compiler.Adapter` | Version-specific extraction, application, optional body checking |
| `SpecLint.Typespec` | Erlang typespec AST normalization and named-type resolution |
| `SpecLint.Translation` | Descr bounds and structured precision losses |
| `SpecLint.Compare` | Pure per-slice relations and diagnostic evidence |
| `SpecLint.Coverage` | Counts, unavailable/inconclusive reasons, coverage policy |
| `SpecLint.Baseline` | Stable matching, reasons, expiry and stale entries |
| `SpecLint.Reporter.*` | Human, JSON, SARIF rendering |

Return data from library functions. Keep `System.halt/1` and Mix failure handling at the task boundary. Start and stop checker caches reliably even after exceptions.

### Backend A: compiled signatures, first release

Use compiled typespecs and `ExCk` inferred signatures through a tested adapter. Read exact project build paths; do not discover modules by scanning every loaded module or calling every module's `__info__/1`. Dependencies are available for type resolution and inference, but are not lint targets by default.

The adapter owns chunk versions, signature layouts, Descr operations, checker cache lifecycle, and application semantics. [T] currently copies [A]'s application rule and cutoff; either obtain a narrow upstream application entry point or retain the copy with differential tests against each supported compiler revision. A function's existence is not sufficient evidence of compatibility.

Start with a pinned, tested 1.21 development revision, consistent with this project's current requirement. Publish an explicit support matrix and capability report. Do not imply that every build matching `~> 1.21-dev`, or an earlier release, has the same private API. Unknown compiler/chunk combinations fail preflight in CI; developer mode can report unsupported capability without attempting unsafe decoding.

Basic signature mode should not require the `warnings/7` patch. It can ship as an ordinary dependency on a qualified compiler. It will have weaker precision for delegated/remote calls and input-specialized returns; report that limitation rather than substituting declared return specs as inferred evidence.

### Backend B: spec-domain body analysis

[H]'s new `warnings/7` accepts a function returning `:default` or `{mode, argument_descrs}`, and returns diagnostics plus local signatures. Debug-info definitions avoid reconstructing inference from source text. This is a useful starting point, but the hook is not assumed to exist on stock releases.

Initially expose `--analysis bodies` only on qualified patched builds. If explicitly requested and unavailable, fail with an actionable capability message; do not silently switch backends. Later seek a small upstream API for “infer this definition under these argument domains,” including provenance, diagnostics, and capability version.

Change the prototype's body algorithm before promoting results into the gate:

1. Analyze one target function/spec slice at a time in fresh context. Keep the entire tuple domain and its return obligation.
2. Assume only the target's input slice. Leave helpers under ordinary inference and propagate actual call arguments where supported. Never treat the target or a recursive cycle's declared return as evidence for that same contract.
3. Validate local-call caching, recursive functions, mutual recursion, and termination/widening behavior. The existing module-wide hook may require extension; merely invoking it once per slice does not establish correct call-sensitive inference.
4. Prefer the prototype's dynamic-domain mode initially. Keep static-domain mode experimental; the historical report found additional noise there.
5. Compare ordinary body diagnostics with spec-domain diagnostics. Preserve new warnings, but classify unreachable defensive clauses as informational rather than automatically calling the spec invalid.
6. Cache by module, slice, compiler adapter, and relevant dependencies. Enforce budgets; timeout or widening produces explicit incomplete/inconclusive analysis.

Do not replace or hot-load patched `Module.Types` modules into a consumer's Mix VM. If a bundled compiler engine becomes necessary, use an isolated worker and version the full engine consistently. That is a larger maintenance commitment than the proposed initial dependency.

## 6. Translation needs a stricter precision model

[T] documents the invariant that inexact translations over-approximate the spec. Preserve the intent, but audit the implementation rather than accepting the comment as proof.

Represent each translated node with original AST, module context, optional lower bound, upper bound, exactness, and loss records such as `integer_range_erased`, `recursive_expansion_cutoff`, `unresolved_remote_type`, `opaque_boundary`, `type_variable_correlation`, and `higher_order_approximation`. Retain the location of each loss within the type tree.

Key requirements:

- Preserve the remote argument qualification fix already in [T]. Cache resolved types by module artifact hash, type name/arity, and normalized arguments.
- Integer literals/ranges, sized binaries, character types, and similar refinements must not be called exact when widened. A return of `integer()` fitting a widened `pos_integer()` is inconclusive about positivity.
- Preserve proper/improper list tails and required/optional map keys. The prototype's corrected improper `iolist()` approximation is a useful regression fixture. Validate overlapping map associations and broad keys separately before claiming exact translation.
- Track cycles explicitly and apply budgets. Recursive cutoff to `term()` is a reported loss, not success. Native recursive Descr support is a later optimization requiring bounded equivalence tests.
- **Function types need polarity-aware bounds.** Widening an arrow's input generally narrows the function set because of contravariance. [T] recursively widens arguments and passes them to `fun(args, ret)`; its blanket over-approximation claim therefore needs specific validation for higher-order types. Initially use a demonstrably safe arity/top abstraction or mark unsupported when bounds cannot be justified. Do not let uncertain arrows produce hard conflicts.
- Repeated type variables carry relationships. Substituting a bound independently into arguments and return loses correlations even if each bound is exact. For example, a bounded identity contract cannot be validated just by comparing the same union in both positions. Report relational loss until supported.
- [T] expands `:opaque` and `:nominal` bodies along with ordinary types. A product needs explicit abstraction boundaries: external opaque/nominal identity must not silently become structural equality. Use supported nominal semantics or report an opaque-boundary limitation; optional representation inspection must be labeled separately.
- Unsupported constraints, malformed metadata, and unresolved types have structured reasons. Recover per spec clause where possible; one unsupported overload must not silently discard all other analysis or make the whole function appear validated.

## 7. Mix task and CI experience

Proposed installation after packaging:

```elixir
{:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false}
```

Proposed commands, not implemented yet:

```sh
mix spec_lint
mix spec_lint --ci
mix spec_lint --ci --profile soundness
mix spec_lint --analysis bodies --module MyApp.Store
mix spec_lint --format json --output spec-lint.json
mix spec_lint --format sarif --output spec-lint.sarif
mix spec_lint.baseline --output .spec_lint_baseline.json
```

Compile by default via the Mix lifecycle, without starting the application. Normal compilation can run macros and compile-time code; the analysis phase must not invoke arbitrary target functions, start supervision trees, or fuzz application APIs. A `--no-compile` option must validate artifact freshness or explicitly mark an artifact-only run; CI cannot silently certify stale source.

At umbrella root, analyze owned child applications once and aggregate results. Respect `MIX_ENV` and `MIX_TARGET`, record them in output, and resolve the dependency graph under that environment. Support application/module/path filters, but mark filtered runs as partial. A filter matching nothing is an error. Default scope is exported Elixir functions with specs; explicitly count macros, protocol dispatch functions, private functions, generated definitions, and Erlang modules as out of scope or unavailable. Protocol implementations can be analyzed when ordinary supported signatures exist. Behavior conformance and missing-spec style checks are separate future rules.

Example `.spec_lint.exs`:

```elixir
[
  analysis: :signatures,
  profile: :review,
  baseline: ".spec_lint_baseline.json",
  checks: [
    possible_missing_return: :warning,
    possible_missing_input: :off,
    return_can_be_narrower: :off
  ],
  coverage: [fail_on_regression: true],
  exclude: ["lib/generated/**"]
]
```

CLI options override config; reject unknown settings. Explain exclusions in the report. Exit codes: `0` for accepted policy result, `1` for new gated findings/coverage violations, `2` for incomplete execution, unsupported requested backend, configuration error, or internal failure. Normalize compile failures into the task's documented failure result without hiding compiler output.

Consumer CI can initially be just:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix spec_lint --ci --format json --output spec-lint.json
```

The task performs the needed compile. Pin the Elixir/OTP toolchain in CI. Upload the report even when lint fails. No random seeds, network lookup, runtime witness search, or LLM verdicts belong in this gate.

## 8. Baselines, coverage, and reproducibility

Replace MFA-only exclusions with versioned baseline records containing rule, application/MFA, normalized spec-slice identity, stable finding fingerprint, reason, and optional owner/expiry. Fingerprints should include the relevant semantic evidence and body/dependency digest, not line numbers or rendered Descr text alone. Deduplicate equivalent findings across backend stages without hiding distinct slices.

A finding changing in an acknowledged function must be reviewed again. Compiler/adapter version changes require deliberate baseline reconciliation rather than silently adopting old judgments. Record versions separately so users can see why matching changed. Baseline generation writes a review artifact; ordinary lint never regenerates it. Treat stale acknowledgements as warnings locally and failures in CI when the corresponding scope was fully analyzed. A partial run cannot declare unseen entries stale.

Track coverage independently of findings:

- Owned modules discovered and inspected; metadata extraction failures.
- Specs/functions/slices found, compared, and unsupported.
- Exact versus approximate translations, with reason counts.
- Signature available/unavailable and body analysis requested/completed.
- Return obligations established, compatible only after approximation, possible mismatches, and unconstrained/inconclusive results.
- Intentional out-of-scope categories and explicit exclusions.

Do not report “98% validated” by combining equality, wider inference, and absent signatures. Show exact counts and denominators. Compare coverage per owned function/slice against the baseline inventory: loss of metadata, disabled inference, or a supported slice becoming unknown must be visible. New unsupported specs need acknowledgement under CI policy. A real source deletion is not itself a coverage regression; disappearance of analysis while the definition remains is.

If a whole module loses spec/debug metadata, do not infer that it now has zero specs. Compare the previous inventory and available source/build metadata, or fail closed when absence cannot be distinguished. An initial project with genuinely no eligible specs may return success, but must say “0 specs checked”; configured coverage floors can forbid this.

Version JSON independently from compiler data structures. Include tool/adapter/compiler/OTP versions, checker chunk version, source and BEAM hashes, config digest, scope, analysis capabilities, diagnostics, coverage, baseline decisions, and overall completion/policy result. Keep machine output on stdout or in the requested file; send progress elsewhere. Sort deterministically and write reports atomically. SARIF uses the same finding IDs and source locations; fall back to definition/module locations when spec metadata lacks precise positions.

Cache under the project's build directory. Key results by tool/adapter versions, compiler and OTP, BEAM/debug/spec content, resolved remote-type dependencies, inference dependencies, config, environment, and analysis mode. Initially prefer broad invalidation when dependencies change over an unsound incremental shortcut. Validate loaded compiler provenance, borrowing [V]'s checks against stale BEAMs. Do not serialize private Descr values for reuse across incompatible compiler versions.

## 9. Validation and implementation plan

### Phase 1: extract a useful signature linter

Extract [T]'s translator and comparison engine into this project, add the compiler adapter and Mix discovery, and replace combined verdicts with per-slice diagnostics/coverage. Ship console and JSON output, both gate profiles, and structured baselines. Preserve supported behavior while adding missing-return warnings and eliminating silent skips. Keep the body backend disabled unless explicitly selected on a supported build.

Acceptance criteria:

- A consumer fixture invokes `mix spec_lint --ci` successfully without an Elixir source checkout, using the documented supported toolchain.
- Fixtures detect disjoint returns, missing tagged return alternatives, rejected input domains, and `no_return()` uncertainty.
- Intentional broader return contracts pass default checks; top-only inference remains explicitly inconclusive.
- Missing chunks/spec metadata, unknown chunk versions, zero matches, crashes, and timeouts cannot produce a normal green analysis.
- Umbrella aggregation, environment selection, baseline matching, changed acknowledged findings, and partial-run stale handling have integration tests.

### Phase 2: qualify spec-domain analysis

Extend or replace [H]'s hook as needed for per-slice root assumptions. Add debug-info extraction and capability negotiation. Run fixtures for correlated argument pairs, overlapping overloads, defaults, private helpers, cross-module calls, defensive clauses, recursion, mutual recursion, and generated definitions. Show whether the stronger backend resolves or merely restates each signature finding.

The historical body report gives a useful expectation: among 1,781 checked functions it recorded 926 wider inferred returns and 49 incomparable returns. Treat these as evidence that naive “not a subtype => invalid spec” would be noisy, not as current benchmarks or proof of linter precision.

### Phase 3: assurance, reporting, and broader compiler support

Adapt [O]'s bounded membership models to test translation direction over controlled concrete values. Include improper lists, map associations, integer refinements, recursive aliases, variable correlation, and function-arrow polarity. Function-valued cases that the oracle classifies weak/unverifiable cannot count as proof.

Reuse [V]'s mutation-canary approach: deliberately drop a return alternative, corrupt a signature application rule, skip a metadata error, accept an old report, broaden an acknowledgement, or return exit zero after a worker failure. Each mutation must make the test gate fail. Keep independent oracle tests so matching bugs in the translator and comparator do not validate each other.

Run cheap translator/adapter/canary tests for every SpecLint change. Run the larger finite-model and checker fuzz suites in scheduled/toolchain-qualification jobs, with exact provenance and narrow known-defect records. Do not claim the existing full verification profile is green; reproduce and triage its known residuals for each selected toolchain.

Then add SARIF, stable path filtering, cache optimization, and additional tested compiler adapters. Measure cold/warm runtime, memory, comparable/inconclusive coverage, and actionable findings on the Elixir corpus plus ordinary Mix and umbrella fixtures. Set performance budgets only after measurement.

The first release should be judged on whether it catches omitted return alternatives, gives useful explanations, and can gate changes without hiding lost coverage. Full spec-domain inference, nominal fidelity, relational polymorphism, and proof of runtime reachability are subsequent capabilities, not claims required to ship a useful CI linter.
