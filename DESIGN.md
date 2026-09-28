# SpecLint design

Combined design, 2026-09-28. Merges `DRAFT_FABLE.md` and `DRAFT_ASTRA.md`
and the cross reviews of each. Decisions that resolve a disagreement between
the drafts are marked **Decision**.

## 1. Summary

SpecLint is a Hex package providing `mix spec_lint`, a Credo-style task that
checks Dialyzer-style `@spec` declarations against the types the Elixir
compiler infers. It reads compiled BEAM files, translates each spec into the
compiler's set-theoretic type lattice (`Module.Types.Descr`), compares each
spec clause against the inferred signature stored in the `ExCk` chunk, and
reports findings with stable rule IDs, an evidence class, and a severity. In
CI it fails on new findings not acknowledged in a baseline and on loss of
analysis coverage. It runs no Dialyzer, needs no PLT, and its analysis phase
never invokes target functions.

The prototype exists on the `ls-typespec-tightening` branch of `~/elixir` as
`lib/elixir/scripts/compare_specs_and_signatures.exs`. SpecLint extracts its
pipeline and corrects three things the prototype got wrong for a general
linter: it dropped the "inferred return wider than spec" case that is the
main product value, its translator's over-approximation invariant does not
hold for function types, and its coverage accounting let analysis disappear
silently.

**Decision: evidence model and CI safeguards from Astra, implementation
structure from Fable, and a smaller first milestone than either draft.**

## 2. Background

### 2.1 What the branches provide

`ls-typespec-tightening` (tip `7190b0285`) is the product prototype:

- `SpecToDescr`: Erlang typespec AST (from `Code.Typespec.fetch_specs/1`) to
  `Descr`, with one exactness boolean per argument list and per return,
  recursive expansion of user and remote types to depth 8, `when` constraint
  substitution, and a fix that qualifies remote type arguments in the
  caller's namespace.
- `Verdict`: per spec clause, applies the inferred signature to the spec's
  argument types with a copy of `Module.Types.Apply.apply_infer/2` (including
  its 16-clause cutoff), then classifies with `subtype?/2` and `disjoint?/2`
  into `equivalent`, `inference_wider`, `spec_wider_return`, `contradiction`,
  `mixed`. Adds an all-`dynamic()` argument probe.
- A body check that re-runs the type checker with spec-derived argument
  domains via a new `Module.Types.warnings/7` hook (28-line compiler patch).
  It applies domains to every spec'd function in the module in one run and
  unions multi-clause spec domains per position.
- An MFA-only exclusions file with 68 entries, a `make check_specs` target,
  and a CI step.

`ls-formal-verification` (tip `275dfc58c`) contains no spec comparison. It
verifies the type algebra, checker transfer functions, inferred signatures and
hard-coded BIF signatures with finite models, generated programs and runtime
witnesses. SpecLint reuses its methods, not its runs: fail-closed coverage
counters, fingerprint-pinned expected failures that go stale, mutation
canaries, a result envelope with provenance, deterministic seeds and sorted
iteration. Its recorded full run is not green (19 pass, 6 expected failures,
4 failures), so neither inference nor any oracle is treated as ground truth.

Untracked reports in `~/elixir` (`SPEC_DOMAIN_BODY_CHECK_REPORT.md`,
`SPEC_TIGHTENING_CANDIDATES.txt`, July 2026, older tree) give historical
context only. Their headline number matters for design: of 1,781 stdlib
functions checked under spec domains, 926 had an inferred return wider than
the spec and 0 were disjoint. A naive "not a subtype means bad spec" rule is
therefore unusable; the design below is built around making the wider case
useful.

### 2.2 Facts about the compiler that constrain the design

- Inferred signatures are `{:infer, domain, [{args, ret}]}`. Stored clause
  returns may be static (verified: `Keyword.new/0` stores a non-gradual
  return) or gradual; it is the *application* result of
  `Module.Types.Apply.apply_infer/2` that is always wrapped in `dynamic()`.
  Domains come from patterns and guards only. Returns are
  over-approximations. Comparisons use bounds or gradual `subtype?/2`, never
  raw term equality. Precision of a stored clause is read from the stored
  clause, never inferred from the wrapped application result.
- `Descr` function types are contravariant in arguments. Verified on the
  local tree: `fun([atom()], integer())` is a subtype of
  `fun([atom([:a])], integer())`. Widening an arrow's argument therefore
  narrows the set. The prototype does this, so its invariant is broken for
  higher-order specs.
- The `Descr` printer is not faithful (`fun(n)` versus `none()` arguments,
  `dynamic(t)` printed as `t` unless `skip_dynamic_for_indivisible: false`,
  some list forms not rebuildable). Printed strings are presentation only.
- Everything used is `@moduledoc false`: `Module.Types.Descr`,
  `Module.Types`, `Module.ParallelChecker`, `:elixir_erl.checker_version/0`,
  the `ExCk` layout. The map field encoding inside `Descr` changed once
  during the verification branch's life and broke scripts.
- `Kernel.Typespec` expands `%Mod{}` into explicit map fields before storing
  the spec, so no struct reconstruction is needed on the spec path.
- `Macro.t()` is an ordinary recursive type alias, not opaque. Recursion
  cutoff and opacity are different translation losses.
- Specs and types are read from the `Dbgi` chunk, so `debug_info: true` is
  required even without body analysis. Only persisted module attributes reach
  the BEAM and they carry no source line association.
- The compiler infers signatures for the module being compiled whenever
  `infer_signatures` is not `false`; the option's application list only
  controls which dependency signatures callers see. Protocol modules and
  `behaviour_info/1` get no signature.

## 3. Contract and evidence model

For each spec clause keep the argument tuple domain `D` and return set `S`.
The obligation is partial correctness:

```
for calls with arguments in D, every normal return belongs to S
```

A spec does not promise termination or absence of raises, an implementation
may handle inputs outside `D`, and `S` may reserve alternatives the current
implementation never produces.

Two kinds of uncertainty are kept apart and named differently:

- **Translation bounds.** When a spec construct cannot be expressed exactly,
  the translator produces `S_lo` and `S_hi` with `S_lo ⊆ S ⊆ S_hi`, plus a
  structured loss record. Same for each argument position. For most losses
  only `S_hi` is useful; `S_lo` may be `none()`.
- **Gradual bounds.** `Descr.lower_bound/1` and `upper_bound/1` describe the
  `dynamic()` component of an inferred type. `U(D)` below always means the
  gradual upper bound of the inferred return applied at `D`.

The two are never merged into one pair.

| Relation | Permitted conclusion |
| --- | --- |
| `U(D) ⊆ S_lo` | Obligation established within the model |
| `U(D) ⊆ S_hi`, translation inexact | Compatible at available precision |
| exact `S`, `U(D) ⊂ S` strictly | Tightening hint |
| `U(D) − S_hi` non-empty | Possible undeclared return; not a reachability proof |
| `U(D)` non-empty and disjoint from `S_hi` | Any normal return violates the spec; does not prove a return happens |
| `U(D) = none()` | No normal return predicted; not by itself a bad spec |
| spec `no_return()`, `U(D)` non-empty | Possible unexpected return; inference does not prove returnability |

Overloads: `(atom(), atom())` and `(integer(), integer())` stay two domains
with their own returns. Overlapping overloads get an explicit `overlap` tag
and are downgraded to review until the intended typespec semantics is
validated. The per-position union is never used for a gating result.

### 3.1 Structured extra-return evidence (the `SL002` classifier)

This is the predicate behind the most important rule. It is a conservative
recogniser with an explicit `unknown` result, not a complete definition, and
it gates nothing until the Phase 0 experiment (section 11) has measured it.

Inputs for one spec slice: translated argument bounds `D_lo`, `D_hi` with
their loss records, translated return `S_hi`, the set of inferred clauses
`{I_k, R_k}` that the application rule selected for the slice, and the
applied return `U(D)`.

1. `extra = difference(U(D), S_hi)`. Empty means no finding.
2. If the upper bound of `U(D)` is `term()`, evidence is `unknown`
   (top-only inference). Record in the ledger; do not warn.
3. **Domain containment.** For each contributing clause, try to establish
   `I_k ⊆ D_hi` as a tuple domain (positionwise subtyping is only a
   sufficient condition when the spec slice is a product; correlated
   overloads are compared as whole tuples). Three outcomes:
   - contained: the clause's return arises within the spec domain;
   - `domain_escape`: some inputs accepted by the clause are outside the
     spec domain (this covers both "strictly wider" and incomparable
     domains such as `atom() | integer()` against `atom() | binary()`);
   - `containment_unknown`: containment cannot be decided because a loss
     record on an argument position widened `D_hi`.
4. **Input approximation.** If any argument position of the slice has a
   loss record (for example `pos_integer()` erased to `integer()`), the
   slice is `input_approximate`. Extra returns may then be produced by
   inputs the original spec excludes even when every clause is contained
   (regression fixture: `@spec classify(pos_integer()) :: :positive` whose
   body returns `:nonpositive` for `n <= 0`).
5. **Structure recognition** on `extra` and on each contributing `R_k`.
   The recogniser walks the `Descr` term through the adapter (unions of
   per-kind components; intersections and negations inside a component
   yield `unknown` for that component) and labels each component:
   - `structured`: finite atom set; tuple with fixed arity whose first
     element is a finite atom set; closed map or struct with known keys;
     list whose element type is itself `structured`;
   - `whole_kind`: an entire base kind (`integer()`, `binary()`,
     `tuple()`, `map()`, `fun()`, `list(term())`);
   - `unknown`: anything the recogniser does not understand.
   A component counts as evidence only if the same structure is present in
   a contributing `R_k`, not only in the difference, so structure created by
   subtracting the spec is not mistaken for structure inference derived from
   code.
6. Classification:
   - `structured_possible`: at least one `structured` component, all
     contributing clauses contained, slice not `input_approximate`;
   - `possible_domain_escape`: structured component but some clause escapes
     or containment is unknown;
   - `possible_input_approximate`: structured component but the slice's
     inputs were widened by translation;
   - `whole_kind_possible`: only `whole_kind` components (for example the
     spec says `integer()` and inference says `integer() | binary()`);
   - `unknown`: only `unknown` components.

Whole-kind omissions are real omissions in many codebases. Their default
suppression is a measured tradeoff: the fixture corpus includes them and the
experiment reports how many the filter drops.

Body analysis under the exact slice *may* resolve `possible_domain_escape`
and `possible_input_approximate`; helper inference and other approximations
can remain imprecise.
## 4. Rules

Each finding has a rule ID, an evidence class (`conflict`,
`structured_possible`, `possible_domain_escape`, `possible_input_approximate`, `whole_kind_possible`, `unknown`, `hint`), a severity, and the gating
prerequisites that were met.

| Rule | Meaning | Gating prerequisites | Default |
| --- | --- | --- | --- |
| `SL001 return_conflict` | `U(D)` non-empty and disjoint from `S_hi` on a slice | translation of the slice has no `unsupported` loss, no `overlap` tag, no arrow in the return | warning, gated in both profiles |
| `SL002 possible_missing_return` | structured extra per section 3.1 | same as SL001 plus classification `structured_possible` | warning; CI behaviour per the policy table below |
| `SL003 spec_domain_rejected` | the application rule matches no inferred clause on an inhabited spec slice, or a spec argument position is disjoint from every inferred domain | translation of the arguments exact or upper-bounded only, no `overlap` | warning, gated in both profiles |
| `SL004 possible_missing_input` | inferred domain accepts shapes outside the spec domain | none | off, hint |
| `SL005 return_can_be_narrower` | exact `S`, `U(D)` strictly inside | none | off, hint |
| `SL006 possible_unexpected_return` | `no_return()` spec, `U(D)` non-empty | none | review, gated in `review` profile |
| `SL007 spec_domain_body_warning` | checker diagnostic under the spec assumption (body backend only) | body backend qualified | informational |
| `SL008 analysis_unavailable` | missing debug info, missing chunk, unsupported chunk version, untranslatable construct, no inferred signature | none | coverage ledger, gated by coverage policy |

CI policy by evidence, independent of the rule's severity:

| Finding | `soundness` profile | `review` profile |
| --- | --- | --- |
| Supported conflict (SL001, SL003 with prerequisites met) | gate | gate |
| `structured_possible` return (SL002), SL006 | report | gate |
| `possible_domain_escape`, `possible_input_approximate`, `whole_kind_possible` | report | report |
| `unknown` | ledger only | ledger only |
| Unsupported execution or capability (SL008) | execution and coverage policy | execution and coverage policy |

`--warnings-as-errors` gates every *reported* finding of every enabled rule,
including the report-only rows. It is an explicit user policy choice and is
documented as overriding the evidence prerequisites; it never promotes
`unknown` or ledger entries. A rule's severity setting changes how a finding
is printed, never whether it gates.

Wording rules: a disjoint result is reported as "any normal return would be
outside the spec", never as "the function returns the wrong type". A
rejected domain is "the checker would warn on every call in this slice",
never "every call crashes".

Message shape:

```
lib/store.ex:12: SL002 possible_missing_return Store.lookup/1
  spec:            lookup(:present | :missing) :: {:ok, integer()}
  inferred extra:  {:error, :missing}
  slice:           (:present | :missing)
  evidence:        structured_possible (signature backend, translation exact)
  Review whether the spec should include this alternative.
```

Types are printed with `Descr.to_quoted/2` and
`skip_dynamic_for_indivisible: false`.

## 5. Architecture

```
mix spec_lint
  -> Mix compile (project lifecycle, application not started)
  -> SpecLint.Project     owned BEAM files, umbrella children, MIX_ENV/TARGET
  -> SpecLint.Compiler    preflight: Elixir version, checker chunk version,
                          capability report (signatures / bodies)
  -> SpecLint.Beam        per module: ExCk, Dbgi specs and types, debug_info
  -> SpecLint.Translate   spec AST -> {lo, hi} Descr bounds + loss records
  -> SpecLint.Compare     per slice: application, relations, evidence
  -> SpecLint.Bodies      optional, qualified builds only
  -> SpecLint.Rules.*     relations -> findings
  -> SpecLint.Coverage    ledger, regression against baseline inventory
  -> SpecLint.Baseline    fingerprint match, stale detection
  -> SpecLint.Report.*    console, JSON (SARIF later)
  -> exit status at the task boundary only
```

### 5.1 `SpecLint.Beam`

Reads each `.beam` under the project's compile paths with `:beam_lib`.
Modules are discovered from build paths, never by scanning loaded modules.
Per module:

- `ExCk`: `binary_to_term` gives `{version, %{exports: [{{f, a}, %{sig: sig}}], mode: mode}}`.
  `version` must equal `:elixir_erl.checker_version/0` of the running
  compiler; otherwise the module is `SL008 unsupported_chunk` and, in CI,
  the run fails preflight.
- Specs and types via `Code.Typespec.fetch_specs/1` and `fetch_types/1` on
  the binary. `:error` is recorded as `SL008 missing_metadata`, never as
  "no specs".
- `debug_info` decoded to `:elixir_v1` for definitions and lines. Missing
  debug info disables body analysis loudly, not silently.

Remote types resolve through `:code.which/1` and are memoised per run by
`{module, name, arity}` and beam md5.

### 5.2 `SpecLint.Compiler` adapter

One module per qualified compiler revision. It owns: the chunk decoder, all
`Descr` calls, the copy of `apply_infer/2` with its clause cutoff, and the
optional `warnings/7` bridge. Qualification means the differential tests in
section 10 pass for that revision, not that a function is exported. The first
release pins one 1.21 development revision and publishes a support matrix.
Unknown combinations fail preflight in CI and report "unsupported" locally.

**Decision:** direct chunk reading from Fable for signatures; the
`Module.ParallelChecker` cache is started only for body analysis, and is
stopped in an `after` block.

### 5.3 `SpecLint.Compare`

Pure functions over translated slices and inferred clauses, returning raw
per-slice relations: `applied_return`, `extra`, `missing`, `domain_relation`
per position, `badapply?`, `overlap?`, `domain_overlap?`, contributing
clauses. The prototype's `combine/1` verdict ranking is not used. Rules
consume the raw relations, so no case is lost to an early classification.

### 5.4 `--explain Mod.fun/arity`

Prints the spec clauses, translated bounds with every loss record and its
position in the type tree, the inferred clauses, which clauses applied to
each slice, `extra` and `missing` per slice, the evidence class, and which
prerequisite blocked or enabled gating.

## 6. Translation

`SpecToDescr` is the starting point but is audited, not lifted. Each
translated node records original AST, module context, `lo`, `hi`, and a list
of losses, each with a path into the type tree:

`integer_refinement_erased`, `sized_binary_erased`, `charlist_as_integers`,
`recursive_cutoff`, `unresolved_remote_type`, `opaque_boundary`,
`nominal_boundary`, `type_variable_correlation`, `arrow_polarity`,
`record_fields_unknown`, `unsupported_construct`.

Rules:

- Keep the remote argument qualification fix and the improper `iolist()`
  regression fixture.
- Arrows: an argument that translates inexactly cannot be widened. Use
  `fun(arity)` as `hi` and `none()` as `lo`, record `arrow_polarity`, and
  exclude the slice from `SL001` gating. Exact arrows translate as
  `fun(args, ret)`.
- Repeated type variables: substitute the bound, record
  `type_variable_correlation`, and treat the return as `hi` only.
- `@opaque` and `@nominal` from other modules: `term()` as `hi`, `none()` as
  `lo`, `opaque_boundary`. Optional structural expansion is a separate flag
  and is labelled in output. The lattice has no nominal support today.
- Recursive types: depth budget, cutoff to `term()` recorded as
  `recursive_cutoff`, never counted as exact.
- Literal map types stay closed; an association with a non-literal key opens
  the map and records a loss. Overlapping associations are validated in
  tests before being called exact.
- Erlang records stay open tuples tagged with the record name.
- One unsupported construct marks that slice `unsupported`; other slices of
  the same spec are still analysed.

**Decision:** no `__info__(:struct)` reconstruction. The compiler already
expands structs on the spec path.

## 7. Body analysis (backend B)

Available only on qualified builds carrying the `warnings/7` hook. Requested
and unavailable is an error with a capability message, not a silent
fallback. Patched `Module.Types` modules are never hot-loaded into the
consumer's VM.

Before any body result gates CI:

1. One target slice at a time with the full tuple domain, in fresh checker
   context. Helpers stay under ordinary inference. The target's declared
   return is never used as evidence for itself or for a recursive cycle.
2. Dynamic-domain mode by default; static mode stays experimental (the
   historical report found 18 static-only precision artifacts and no bugs).
3. Diff ordinary diagnostics against spec-domain diagnostics; unreachable
   defensive clauses are informational.
4. Measure cost per slice on `Enum` and `Keyword` before committing to the
   per-slice loop. If too slow, batching is allowed only when each slice
   keeps its own environment and its own return; a positional union of
   disjoint slices such as `(atom(), atom())` and `(integer(), integer())`
   still invents mixed pairs and is forbidden.
5. Validate local-call caching, recursion, mutual recursion and widening in
   fixtures.

Long term, ask upstream for a small API "infer this definition under these
argument domains" returning diagnostics, signature and capability version.

## 8. Mix task and configuration

```
{:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false}
```

```
mix spec_lint                       warnings, no findings-based failure
mix spec_lint --ci                  review profile unless configured
mix spec_lint --ci --profile soundness
mix spec_lint --explain MyApp.Store.lookup/1
mix spec_lint --analysis bodies --module MyApp.Store
mix spec_lint --format json --output spec-lint.json
mix spec_lint.baseline --output .spec_lint_baseline.json
```

Behaviour:

- The task parses its options first and then invokes `Mix.Task.run("compile")`
  explicitly (no `@requirements`, which would run before `run/1` and make
  `--no-compile` impossible to honour). Compile failures are turned into the
  documented exit 2 with the compiler output shown. The application is not
  started. The promise is "analysis does not invoke target functions", not
  "no project code runs", because compilation runs macros.
- `--no-compile` is not in the first release. When added it validates
  artifact freshness against the Mix manifest or marks the run
  artifact-only in the report.
- Umbrella root analyses owned children once and aggregates. `MIX_ENV` and
  `MIX_TARGET` are recorded in output.
- Filters (`--app`, `--module`, paths) mark the run partial. A filter matching
  nothing is an error.
- Default scope is exported Elixir functions with specs. Macros, protocol
  dispatch functions, private functions, generated definitions and Erlang
  modules are counted as out of scope in the ledger.
- Profiles: `soundness` gates SL001, SL003 and coverage regressions;
  `review` adds SL002 and SL006. `--warnings-as-errors` gates every enabled
  warning rule.
- Exit codes: 0 accepted, 1 new gated findings or coverage violation, 2
  incomplete run, unsupported backend, configuration error or internal
  failure. Compile failures surface compiler output and exit 2.

`.spec_lint.exs`:

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
  coverage: [fail_on_regression: true],
  exclude: ["lib/generated/**"],
  expand_opaque: false
]
```

Unknown settings are rejected. CLI overrides config.

Inline suppression: **deferred**. Persisted attributes carry no source
association and `@after_compile` runs after the binary exists. When added,
it is an explicit `@spec_lint ignore: {:lookup, 1}, rule: :SL002, reason: "..."`
attribute keyed by MFA, or a source comment `# spec_lint:ignore SL002 reason`
on the line before the `@spec`, resolved through the definition's line from
debug info. Until then the baseline is the only suppression mechanism.

## 9. Baseline and coverage

Baseline entries are JSON records:

```json
{"rule": "SL002", "mfa": "MyApp.Store.lookup/1", "slice": 0,
 "fingerprint": "sha256:...", "adapter": "1.21.0-dev+abcdef",
 "reason": "error tuple is internal", "owner": "team-x", "expires": null}
```

**Decision:** the fingerprint hashes normalised structural evidence: the
spec slice AST after named-type expansion, the loss records, and the
inferred clauses as `Descr` terms serialised through the adapter's canonical
form. It does not hash printed type strings, source lines, function bodies
or dependency digests. Body and dependency hashes are provenance and cache
inputs only. A compiler adapter change is recorded separately and triggers
deliberate reconciliation rather than silent reuse.

The baseline file also carries an **inventory** so coverage policy is
enforceable on the first run, not only as a regression:

```json
{"version": 1,
 "adapter": "1.21.0-dev+abcdef",
 "findings": [ ... ],
 "inventory": [
   {"mfa": "MyApp.Store.lookup/1", "slice": 0,
    "status": "compared", "translation": "exact"},
   {"mfa": "MyApp.Store.dump/2", "slice": 1,
    "status": "unsupported", "reason": "arrow_polarity",
    "acknowledged": "higher-order callback"}
 ]}
```

Coverage rules:

- Inventory and comparison are per function **and slice**. Losing one
  overload while another stays analysed is a violation.
- Categories expected out of scope and never requiring acknowledgement:
  protocol dispatch functions, `behaviour_info/1`, macros, private
  functions, Erlang modules, modules matched by `exclude`.
- Every `unsupported` or `unavailable` slice on an owned function requires
  an inventory acknowledgement in CI. Without a baseline file, CI reports
  them all as new and exits 1; local runs list them.
- A slice present in the inventory as `compared` that is now `unsupported`
  or `unavailable` while its definition still exists is a regression.
- Incomplete or partial analysis never makes an acknowledgement stale.

Stale entries are warnings locally and in CI. `mix spec_lint.baseline`
writes a review artifact; ordinary runs never modify it. A partial run cannot
declare unseen entries stale.

Coverage ledger, reported with denominators and never as a single
percentage: modules discovered and inspected; metadata failures by reason;
specs, functions and slices found, compared and unsupported by reason; exact
versus approximate translations by loss kind; signatures available and
unavailable by reason; body analysis requested and completed; obligations
established, compatible after approximation, possible mismatches, unknown.
Coverage regression is evaluated per owned function against the baseline's
inventory: a definition that still exists but lost analysis is a violation;
a deleted definition is not. A project with zero eligible specs succeeds and
says so, unless a configured floor forbids it.

JSON output is versioned independently of compiler structures and includes
tool, adapter, Elixir and OTP versions, checker chunk version, BEAM hashes,
config digest, scope, capabilities, findings, ledger, baseline decisions and
completion status. Sorted deterministically, written atomically, and byte
identical across two runs on the same inputs.

## 10. Qualification and tests

- Translator tests per construct with expected `lo`, `hi` and losses.
- Direction tests: adapt the verification branch's membership oracle to
  check over controlled concrete values that `S_lo ⊆ S ⊆ S_hi` holds for
  improper lists, map associations, integer refinements, recursive aliases,
  variable correlation and arrows. Weak or unverifiable oracle results do
  not count as proof.
- Differential tests for the `apply_infer/2` copy against the compiler's own
  application on generated clause sets, run per qualified revision.
- Fixture corpus of small modules with known expected findings: omitted
  tagged return, defensive catch-all, delegated call, numeric refinement,
  unconstrained inference, overlapping overloads, correlated variables,
  `no_return()`, recursion, helper called outside its domain.
- Mutation canaries: drop a return alternative, flip `subtype?` arguments,
  widen every spec to `term()`, skip a metadata error, accept an old chunk
  version, exit zero after a worker failure. Each must turn the suite red.
- Determinism and provenance tests on the JSON envelope.
- Consumer integration: an ordinary Mix app and an umbrella under `dev` and
  `test`, with inference on and off, with and without debug info, with stale
  artifacts, with protocol consolidation.
- Stdlib regression over Elixir's own `lib/*/ebin` on the pinned revision.
- The verification branch's large model and fuzz suites run in scheduled
  toolchain-qualification jobs only, never in consumer runs.

## 11. Plan

### Phase 0: investigations (before implementation expands)

1. **Missing-return usefulness, the go/no-go experiment.** No canonical
   `Descr` serialiser and no body analysis are needed for it. Steps:
   hand-written fixtures covering true omissions (tagged tuple, atom,
   whole-kind) and false-positive traps (defensive catch-all, input
   approximation, delegation, top-only inference, incomparable domains);
   raw signature relations from the pinned build; an experimental section
   3.1 classifier; a manually reviewed sample of stdlib findings; and, on
   two or three open-source libraries, a count of detected omissions,
   suppressed omissions and false positives with a warn/no-warn decision
   recorded per fixture. Completion criterion: a written decision whether
   SL002 is default-gating, opt-in gating or informational, with the
   numbers that justify it.
2. **Translation correctness.** Test arrows, repeated variables, overlapping
   map fields, recursive aliases, opaque and nominal boundaries, overloaded
   specs. Decide which constructs may support SL001.
3. **Body hook behaviour.** Fixtures for a spec'd function calling a helper
   outside the helper's domain, recursion, mutual recursion, correlated
   overloads. Time per-slice runs on `Enum` and `Keyword`.
4. **Consumer compilation.** Compile a plain app and an umbrella; confirm
   what the pinned build provides and how `infer_signatures`, debug info and
   consolidation affect the chunks.
5. **Fresh corpus measurements** on pinned revisions: findings by rule and
   evidence, losses by kind, runtime.
6. **Fingerprint stability** (before the baseline release, after the
   usefulness experiment): tests for line changes, clause reordering, a
   fresh VM, and a semantically unchanged recompilation.

### Phase 1: vertical slice

One BEAM reader, one qualified adapter, per-slice comparison, rules SL001,
SL002, SL003, SL006 and SL008, console and JSON output, the fixture corpus,
compiler preflight, coverage ledger and essential canaries. A consumer
fixture runs `mix spec_lint --ci` without an Elixir source checkout.

### Phase 2: CI product

Structured baseline, both profiles, umbrella aggregation, partial-run
semantics, `--explain`, SL004 and SL005, stdlib dogfooding replacing
`make check_specs` with the 68-entry baseline migrated to fingerprints.

### Phase 3: body analysis and breadth

Qualify backend B per section 7, upstream the hook or a replacement API,
SARIF, caching under `_build`, additional adapters, performance budgets set
after measurement.

## 12. Open questions

- Whether `structured_possible` should additionally require the
  contributing stored clause return to be static. The adapter can read
  this from the stored clause (section 2.2).
- Whether overlapping overloads follow Erlang's intersection reading or the
  Elixir checker's union-of-matching-clauses reading; the choice changes
  SL001 on those functions.
- Behaviour callback conformance and missing-spec style checks are separate
  future rules; whether they belong in this package or in Credo.
- Whether dependencies should ever be lint targets (`--include-deps`), given
  consumers cannot fix them.
