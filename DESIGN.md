# SpecLint design

Combined design, 2026-09-28. Merges `DRAFT_FABLE.md` and `DRAFT_ASTRA.md`
and the cross reviews of each. Decisions that resolve a disagreement between
the drafts are marked **Decision**.

## 1. Summary

SpecLint is a Mix package providing `mix spec_lint`, a Credo-style task that
checks Dialyzer-style `@spec` declarations against the types the Elixir
compiler infers. It reads compiled BEAM files, translates each spec into the
compiler's set-theoretic type lattice (`Module.Types.Descr`), compares each
spec clause against the inferred signature stored in the `ExCk` chunk, and
reports findings with stable rule IDs, an evidence class, and a severity. In
CI it fails on new findings not acknowledged in a baseline and on loss of
analysis coverage. It runs no Dialyzer and needs no PLT. It does not start
the target application, but compilation and type-printer operations can load
target modules, executing `@on_load` callbacks and `__info__/1`; this is not
a security sandbox. Use trusted source and artifacts.

**Current qualification policy (2026-09-29):** compiler compatibility is
separate from permission to certify CI (`SpecLint.Compiler.Gating`).
Upstream `648b2a9` is diagnostic-only across the whole build because
defective comprehension signatures can also affect callers. Every finding
is ungated, the run is incomplete, CI and warnings-as-errors exit 2, and
local runs exit 0. Baselines cannot waive this or be written. `c24c235` and
1.20.4 are CI candidates; current-tree requalification remains pending.
Historical release-1/release-2 measurements below do not qualify these
hardening changes.

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

This is the predicate behind `SL002`. It is a conservative recogniser with
an explicit `unknown` result, not a complete definition. The Phase 0
experiment (section 11, `EXPERIMENTS.md`) measured it, and as a result it
gates nothing.

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
   code. This includes payloads. A component whose tag the spec already
   declares does not count when every contributing `R_k` it overlaps has
   `term()` at a position where the component is narrower, and the
   component is outside `S_hi` only because of those positions: with each
   of them widened back to `term()`, every piece of the component meets
   `S_hi`. For example, `{:ok, not pid()}` from a clause returning
   `{:ok, term()}` does not count under a spec of `{:ok, pid()}`, but
   `{:ok, pid(), :b}` from a clause returning `{:ok, term(), :a | :b}`
   counts under `{:ok, pid(), :a}`, because the `:b` comes from the code.
   **Decision (post-Phase 1 review):** the widening check was added
   because the rule as first written hid real stale tags behind a
   narrower sibling payload in the spec. On the stdlib it moves 2
   functions (`DateTime.from_iso8601/2,3`, a `float()` offset from
   arithmetic, the O3 shape) from `unknown` to report-only
   `possible_domain_escape`, and changes no gating result.
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

7. **Per-clause evidence (added after Phase 0, bug O2).** The union `U(D)`
   is top-only whenever a single contributing clause returns `dynamic()`
   (recursion, `Enum.map` with a fun, protocol dispatch), which hid seven of
   the nine real omissions found by hand in Phase 0. So after the union-level
   steps, every contributing clause `k` with containment `contained` is
   examined on its own with `R_k' = upper_bound(R_k)`:
   - `R_k'` top or near-top: clause is `unknown`;
   - `R_k'` non-empty and disjoint from `S_hi`: **`clause_conflict`**.
     Evidence class `clause_conflict` (section 4), reported under SL001
     with the clause index and domain: "the clause matching `(I_k)`
     returns `R_k`, entirely outside the spec". Prerequisites: the SL001
     prerequisites plus the clause is contained and the compiler did not
     already flag it unreachable. The chunk does not record reachability,
     so the prerequisite `clause_reachable` is decided by three checks and
     is blocked when either flags the clause: (1) the compiler's own type
     checker, re-run over the function's debug info in the mode it uses
     for warnings after compilation (`SpecLint.Reachability`), reports a
     pattern or guard diagnostic anywhere in the function (a guard that
     can never succeed, a head that cannot match, a redundant clause);
     stored clauses cannot be mapped to source clauses, so one diagnostic
     blocks every clause conflict of the function; (2) the clause is
     *possibly shadowed*: the upper bound of its domain tuple is a subtype
     of the union of the domain tuples of the stored clauses before it
     (this also covers clauses quoted with `generated: true`, whose
     diagnostics the checker suppresses). Check (2) alone misses a clause
     whose guard contradicts its own pattern: it is stored with its
     pattern domain and its body's return, and nothing covers it (2026-09-29
     review). Check (3), added after Phase 3, requires a bounded positive
     witness for every guarded source clause in the function. A witness
     must match the complete head, satisfy at least one expanded guard
     alternative, and be excluded by every earlier source clause. Only
     supported pure Erlang guard operations are interpreted; no target
     function is called. Unsupported syntax or exhausted search blocks the
     function's clause findings (`data.guard_feasibility: "unproven"`).
     The candidate Cartesian products are capped at 4,096 per expansion.
     Success leaves the prerequisite `unchecked`: it establishes source
     guard feasibility, not source-to-stored clause mapping or normal return.
     A failed required compiler re-check is incomplete analysis, with CI
     exit 2 in either qualification setting. The stored clause return is used, not the wrapped
     application result. The reported clause index is the stored signature
     clause, which is not a source clause index: the checker drops clauses
     whose return is empty (a clause that always raises) and merges clauses
     with equal returns. Since Milestone 4 the finding also names the source
     clause and its line where compiler invariants alone determine it
     (`SpecLint.ClauseMapping`: one source clause, or as many stored as
     source clauses; section 5.5), and says "not determined" otherwise. The
     mapping changes no prerequisite: a diagnostic still blocks every clause
     conflict of the function;
   - otherwise `extra_k = difference(R_k', S_hi)` is classified with step 5
     against `R_k` itself (structure must be present in `R_k`, never only
     in the subtraction), giving a per-clause class.
   The function class is the worst over the union-level class and all
   per-clause classes. Clauses whose containment is `domain_escape` or
   `containment_unknown` never yield a `clause_conflict`. An escaping clause
   contributes at most `possible_domain_escape`. A `containment_unknown`
   clause contributes at most `possible_input_approximate`, the same
   reading as the union level: Compare reports `containment_unknown` only
   when input approximation hides containment.
8. **Near-top (added after Phase 0, bug O1).** `U` counts as near-top,
   and is treated like top-only, when its upper bound contains `term()`
   minus a finite set of atoms, or when `difference(U, S_hi)` contains all
   of `pid()`, `port()`, `reference()` and `fun()` whole (no ordinary code
   produces those by accident; their presence means inference gave up).
   The reason `near_top` is recorded in the ledger.
9. **Gradual payloads (Phase 0, bug O3).** A `structured` component whose
   contributing `R_k` is gradual (`Descr.gradual?/1` on the stored clause
   return) is tagged `payload_gradual`. The classifier takes an option
   `require_static_return`; with it, such components downgrade the class to
   `possible_gradual` (report-only). The experiment reports both settings
   and the default is chosen by the measured numbers: `false` after the
   Phase 1 rerun (section 4).

Whole-kind omissions are real omissions in many codebases. Their default
suppression is a measured tradeoff: the fixture corpus includes them and the
experiment reports how many the filter drops.

Body analysis under the exact slice *may* resolve `possible_domain_escape`
and `possible_input_approximate`; helper inference and other approximations
can remain imprecise.
## 4. Rules

Each finding has a rule ID, an evidence class, a severity, and the gating
prerequisites that were met.

**Decision (post-Phase 1 review): the evidence classes are the ones the
implementation emits**, recorded here because they are the JSON report's
`evidence` field:

- `conflict`: a whole slice is disjoint (SL001) or rejected (SL003);
- `clause_conflict`: one contained inferred clause returns only values
  outside the spec (SL001, section 3.1 step 7), kept apart from `conflict`
  because its evidence and prerequisites differ;
- `structured_possible`, `possible_gradual`, `possible_domain_escape`,
  `possible_input_approximate`, `whole_kind_possible` (SL002, section 3.1);
- `unexpected_return` (SL006);
- `hint` (SL004, SL005);
- `unsupported`, `unavailable` (SL008, the slice or module status);
- `unknown` is never a finding: it is recorded in the ledger only.

| Rule | Meaning | Gating prerequisites | Default |
| --- | --- | --- | --- |
| `SL001 return_conflict` | `U(D)` non-empty and disjoint from `S_hi` on a slice (`conflict`), or a contained clause's stored return disjoint from `S_hi` (`clause_conflict`, section 3.1 step 7) | `conflict`: translation of the slice has no `unsupported` loss, no `overlap` tag, no arrow in the return, no argument with an `arrow_polarity` loss (section 6). `clause_conflict`: no `unsupported` loss, no `overlap` tag, the clause's whole domain non-empty and contained in the argument lower bounds (`clause_contained_in_lo`), and `clause_reachable`; with `clause_local_qualification: false`, the four slice-wide prerequisites of `conflict` plus `clause_contained` and `clause_reachable` | warning, gated in both profiles |
| `SL002 possible_missing_return` | structured extra per section 3.1 | same as SL001 plus classification `structured_possible` | warning, informational: reported in both profiles, never gated by evidence policy (Phase 0 decision, section 11) |
| `SL003 spec_domain_rejected` | the application rule matches no inferred clause on an inhabited spec slice, or a spec argument position is disjoint from every inferred domain | translation of the arguments exact or upper-bounded only, no `overlap` | warning, gated in both profiles |
| `SL004 possible_missing_input` | inferred domain accepts shapes outside the spec domain | none | off, hint |
| `SL005 return_can_be_narrower` | exact `S`, `U(D)` strictly inside | none | off, hint |
| `SL006 possible_unexpected_return` | `no_return()` spec, `U(D)` non-empty and neither top-only nor near-top | none | review, gated in `review` profile |
| `SL007 spec_domain_body_warning` | checker diagnostic under the spec assumption (body backend only) | body backend qualified | informational |
| `SL008 analysis_unavailable` | missing debug info, missing chunk, unsupported chunk version, untranslatable construct, no inferred signature | none | coverage ledger, gated by coverage policy |

CI policy by evidence, independent of the rule's severity. SL002 is report-only
in both profiles. That follows the Phase 0 measurements (`EXPERIMENTS.md`):
on real code SL002 had 0 true positives out of 9 candidates, and none of the 9
confirmed real omissions reached `structured_possible`. The Phase 1 rerun
(`EXPERIMENTS.md`, "Phase 1 rerun") confirmed it: 2 candidates reviewed,
precision 0 of 2, 0 confirmed omissions. The conditions for revisiting this
are in section 12.

**Decision (Phase 1 rerun): `require_static_return` defaults to `false`.**
On 2038 real-code functions it only relabels two refuted report-only
candidates, while on the fixtures `true` loses 2 of the 4 clause-conflict
detections. **`clause_conflict` gates in both profiles**: 0 real-code
candidates, so no gated noise, and 4 of 4 fixture detections with 0 false
positives. Its unreachable-clause prerequisite cannot be read from the
checker chunk. Since the post-Phase 1 review it is approximated from the
stored clause domains, and since the 2026-09-29 review also from the
compiler's own pattern and guard diagnostics, re-run over debug info
(section 3.1 step 7). After Phase 3, bounded source-guard witness search
also blocks unproven guarded functions. A flagged, possibly shadowed or
guard-unproven clause is blocked; a surviving clause remains unchecked.

**Decision (Close phase, 2026-09-29): clause-local qualification is the
default, gating in both profiles.** With `clause_local_qualification: true`
(the default; `--no-clause-local-qualification` or `false` restores the
slice-wide prerequisites), a `clause_conflict` replaces the prerequisites
`no_arrow_in_return` and `no_arrow_polarity_argument` by
`clause_contained_in_lo`: the clause's whole, non-empty domain tuple is a
subtype of the tuple of the argument lower bounds `D_lo` (tuple-wise,
never position by position). Every translation loss, `arrow_polarity`
included, only shrinks `D_lo`, so a loss cannot make a clause look
contained; the stored clause return `R_k` is non-empty, not top or near-top
and disjoint from `S_hi`, which stays an upper bound (an inexact arrow in
the return is `fun(arity)` there, and `Descr` never calls two functions of
the same arity disjoint). `no_unsupported_loss`, `no_overlap` and
`clause_reachable` are kept; the slice-level `conflict` keeps the old
prerequisites. The superseded prerequisites and their states are kept in
the finding's `data`. Measured on 15 real-code corpora (4,204 compared
slices, two of them fresh holdouts frozen before the experiment): one new
gate, `Ash.Page.page_opts/1`, a witnessed true positive; no false positive;
every negative control ungated, including the dead-clause controls the
independent review added (they are blocked by the compiler check of
`clause_reachable`, which also changed the slice-wide policy). The holdouts
had no arrow-blocked clause conflict, so they neither confirm nor
contradict a benefit. The rule for this decision was: default on only if
every newly gating finding on the holdouts and tuned corpora is a triaged
true positive that survived review and every negative control passes.
Measurements, triage and the review are in
`bench/corpus/clause_local_qualification.md`.

**Decision (post-Phase 1 review): SL006 ignores top-only and near-top
`U(D)`.** Steps 2 and 8 of section 3.1 treat such inference as "inference
gave up", not as evidence, and the same reading applies to a `no_return()`
spec: `Map.fetch!/2` on an unknown map gives `term()`, which says nothing
about whether the function returns. Such a slice is ledger-only: its
obligation is `unknown` with the reason `top_only` or `near_top`
(`obligations_unknown_by_reason` in the ledger).

| Finding | `soundness` profile | `review` profile |
| --- | --- | --- |
| Supported conflict (SL001, SL003 with prerequisites met) | gate | gate |
| `clause_conflict` (SL001, per-clause, prerequisites met; reachability approximated, section 3.1 step 7) | gate | gate |
| `possible_gradual` (SL002, only with `require_static_return: true`, default `false`) | report | report |
| `structured_possible` return (SL002) | report | report |
| SL006 | report | gate |
| `possible_domain_escape`, `possible_input_approximate`, `whole_kind_possible` | report | report |
| `unknown` | ledger only | ledger only |
| Unsupported execution or capability (SL008) | execution and coverage policy | execution and coverage policy |

On a compiler permitted to certify CI, `--warnings-as-errors` gates every
*reported* finding of every enabled rule,
including the report-only rows. It is an explicit user policy choice and is
documented as overriding the evidence prerequisites; it never promotes
`unknown` or ledger entries, and it never changes SL008, which always
follows the coverage policy. A rule's severity setting changes how a finding
is printed, never whether it gates. Rule selection (`--rules`, `--except`,
`:off`) does not switch the coverage policy off either: coverage is
evaluated from the inventory in every run, and when SL008 is not selected
its blocking findings become coverage violations (exit 1 in CI).

Wording rules: a disjoint result is reported as "any normal return would be
outside the spec", never as "the function returns the wrong type". A
rejected domain is "the checker would warn on every call in this slice",
never "every call crashes".

Message shape (as implemented; the header also names the slice, the
inferred clause of a per-clause finding and the severity, and a `policy:`
line says whether the finding gates, why, and its baseline state):

```
lib/store.ex:12: SL002 possible_missing_return Store.lookup/1 slice 0 [warning]
  spec:            lookup(:present | :missing) :: {:ok, integer()}
  inferred extra:  {:error, :missing}
  slice:           (:present | :missing)
  evidence:        structured_possible (signature backend, translation exact)
  Review whether the spec should include this alternative.
  policy:          reported, not gated: SL002 is informational (...)
```

A per-clause finding reads `... Store.lookup/1 slice 0 clause #1 [warning]`.

Types are printed with `Descr.to_quoted/2` and
`skip_dynamic_for_indivisible: false`.

**Decision (Milestone 1): printing is presentation only and happens last.**
The classifier (section 3.1), `SpecLint.Compare` and the rules work on
`Descr` terms only; no type is printed or serialised to decide a class, a
prerequisite or a gate. Rules keep finding details unrendered (a type is
`{:type, descr}`), and the reporters and `--explain` print them for the
findings they show, so the number of printed types grows with the number
of rendered findings, not with the number of analysed slices. Printing
every component of every slice had made the Absinthe run take about ten
minutes. The adapter's printer keeps its output: it memoises tuple and map
literals within one call and prints the complement form against a length
budget, stopping once a lower bound of its length shows that `not (...)`
cannot be shorter than the direct form. A length threshold or a structural
guess was rejected because neither reproduced the old choice on the
corpora. Tests pin all three properties: a stub adapter that cannot print
classifies and runs identically, `Run.execute/3` prints no type, and the
printer returns the strings of the previous implementation.

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
  -> SpecLint.Reachability functions with a clause conflict: the compiler's
                          pattern and guard diagnostics, re-run over debug info
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
  the run fails preflight. As implemented, every slice of the module is
  reported with the reason `unsupported_chunk:<found version>`, the run is
  `incomplete` (exit 2 in CI; locally it reports and does not declare
  entries stale), and no inventory acknowledgement accepts it: it is a
  stale build artifact or a compiler mismatch, not a coverage gap.
- Specs and types via `Code.Typespec.fetch_specs/1` and `fetch_types/1` on
  the binary. `:error` is recorded as `SL008 missing_metadata`, never as
  "no specs".
- `debug_info` decoded to `:elixir_v1` for definitions and lines. Missing
  debug info disables body analysis loudly, not silently.

Remote types resolve through `:code.which/1` and are memoised per run by
`{module, name, arity}` and beam md5.

### 5.2 `SpecLint.Compiler` adapter

One adapter module per qualified compiler line, covering the revisions of
that line whose audit shows every internal it reads unchanged (Milestone
3: `V121` covers the 1.21 development revisions `c24c235` and `648b2a9`,
`V120` covers Elixir 1.20.4). It owns: the chunk decoder, all `Descr`
calls, the copy of `apply_infer/2` with its clause cutoff, and the optional
`warnings/7` bridge. Qualification means the differential tests in section
10 pass for that revision, not that a function is exported. The README
publishes the support matrix of qualified builds. Unknown combinations fail
preflight in CI and report "unsupported" locally; a release below the
`elixir:` requirement of `mix.exs` (such as 1.19) is refused by Mix before
SpecLint runs.

As implemented (Milestone 2), `SpecLint.Compiler.V121` is qualified for the
fork revision `c24c235` and upstream `648b2a9`, whose internals are the same
(`bench/corpus/toolchain/audit-648b2a9.md`). An adapter covers several
revisions only when the audit finds every internal it reads unchanged. Beyond
the revision check, preflight runs one capability probe per internal
(`capability_probes/0`): the `Descr` exports, the term layout the adapter
reads directly, the `Descr` semantics it relies on, the checker version, the
`ExCk` layout of a sample chunk, the `apply_infer/2` copy against
`remote_apply/7` on both sides of the cutoff, the pattern and guard checker
on a dead and a live clause, the `Code.Typespec` kinds and the compile
manifest reader. A failing probe fails preflight like an unknown revision.
Inference behaviour that no internal probe can see (such as the `for ...
into:` narrowing of `648b2a9`, audit row 19) is pinned per revision by tests
and listed in the support matrix.

**Two compiler lines (Milestone 3).** `SpecLint.Compiler.V120` is
qualified for Elixir 1.20.4 (revision `759443e`, checker chunk v8,
`bench/corpus/toolchain/audit-1.20.4.md`) next to `V121`. The adapter is
chosen per VM by `SpecLint.Compiler.select_adapter/2` from
`System.version()` and the checker chunk version the running `:elixir_erl`
writes; the chosen adapter's preflight then checks the revision, the
compiler identity and the capability probes. A compiler no adapter covers
fails preflight with the list of supported ones (1.19 is not supported).
The code shared by both adapters is split out without a change in
behaviour: `SpecLint.Compiler.Qualification` (preflight, the probes that
are the same on both lines, chunk decoding, the pattern and guard
re-check) and `SpecLint.Compiler.DescrWalk` (components, printing,
canonical form). Everything that differs stays in the adapters: the set
operations (`union/2` on 1.20, `opt_union/2` on 1.21), the map field and
key domain encoding, the expansion of `term()` (1.20 has no public
`unfold/1`) and of recursive nodes (1.20 has none), the `Descr` probes, the
`apply_infer/2` copy, the chunk version and the pinned build digests.
Functions that only one line's `Descr` exports are called through
`:erlang.apply/3`, so SpecLint compiles without warnings, and passes
Dialyzer, on both lines.

**Compiler identity (Milestone 2 review).** The revision alone does not
identify a build: Elixir takes it from `git rev-parse HEAD`, so a modified
checkout of a qualified commit reports it too (a `c24c235` build with the
row 19 fix reverted passed every probe and gated a correct spec under the
`c24c235` adapter id). The first probe, `:compiler_identity`, compares the
code of the pinned compiler modules (`SpecLint.Compiler.BuildIdentity`:
`Module.Types` and `Module.Types.*`, `Module.ParallelChecker`,
`:elixir_erl`, `:elixir_def`, `:elixir_overridable`, `Code.Typespec`,
`Mix.Compilers.Elixir`) with the digests recorded per revision
(`qualified_builds/0`, audit row 24). Digests leave debug info out and
normalise the build root in literals, so they do not depend on the build
directory, date or OTP 28 patch release; they do depend on the Erlang
compiler, which is why the whole build (where `Kernel` differs between OTP
28.0 and 28.5) is not pinned. Expansion modules are outside the pinned set.
The combined digest is `build_digest` in the capabilities and the report.
A `:debug_info` probe covers the `:elixir_v1` debug info contract
`SpecLint.Beam` reads (definition tuples, `:line`, `:generated`,
`from_super: false`; audit row 23), and the `:typespec_kinds` probe also
covers `Code.Typespec.fetch_specs/1` and `spec_to_quoted/2`.

**Artifacts from another build (Milestone 2 review).** Both qualified
revisions write checker chunk v10 and report `1.21.0-dev`, and Mix
recompiles only when the version changes, so after switching compilers a
project keeps the other build's BEAM files, and their stored signatures
were analysed under the running adapter's id (a CI gate passed, or failed,
with the other compiler's verdict). The adapter decision is now per
artifact as well as per VM: `mix spec_lint` and `mix spec_lint.baseline`
write a `SpecLint.BuildRecord` per owned application
(`_build/ENV/lib/APP/.mix/spec_lint.build`: adapter id, build digest and
the SHA-256 of every BEAM file) after compiling, and compile with `--force`
unless the record names the running build and every BEAM file matches it.
`SpecLint.Run` refuses an application whose record names another build or
whose BEAM files were added or changed since (an incomplete build, exit 2);
an application without a record (an explicit ebin, as in the corpus
runner) is analysed and reported as `unrecorded`. Build-record version 4 accepts each artifact only when a per-module compiler
event proves it was produced in this VM, or an unchanged artifact already
has verified provenance for this build and the same compiler list, which
the record stores. Version 1 to 3 records require a rebuild. An app-wide
successful compile does not establish provenance for orphan BEAMs; the
task refuses them with exit 2 and retains them for explicit repair.

Supported compiler pipelines (Milestone 7) have the shape
`prefix ++ [:erlang, :elixir, :app]`: the three artifact stages exactly
once and in that order at the end, and a prefix holding both `:yecc` and
`:leex` (any order, repeats allowed) and any custom stages, such as
`:elixir_make`, `:phoenix_swagger`, or `file_system`'s alias-implemented
`compile.file_system`. Mix runs the stages in list order and each task at
most once per compilation, so the Elixir and Erlang stages, whose events
attest modules, run after every prefix stage has finished, and a prefix
stage that rewrites a verified BEAM of a module Mix does not recompile
leaves bytes that no longer match the record (exit 2). A changed compiler
list makes the build stale: it is recompiled with `--force` and no earlier
evidence is reused. A custom stage after `:erlang` is refused (exit 2
naming the stage) because compiler events do not attest output bytes and
a later stage could replace attested BEAMs; so are missing or reordered
built-in stages, aliases of `compile`, `compile.all` or a built-in stage
(including a self-alias such as `compile: ["compile --warnings-as-errors"]`),
and built-in task modules not loaded from Mix's ebin. The same rules apply
to umbrella children and source-backed Mix dependencies, which receive the
same per-artifact production records before owned applications compile.

This is stale-artifact checking for trusted project code, not protection
against a malicious project. Code that runs inside the compilation
(prefix stages, macros, module bodies, `after_compiler` callbacks, in the
project or a dependency) can forge a `:modules_compiled` event on Mix's
compiler channel, invoke `compile.elixir` itself and then rewrite its
output, or rewrite BEAMs from a callback, and have a foreign BEAM recorded
as verified. This was equally possible from a module body or an
`after_compiler` hook before prefix stages were accepted; the post-release
review reproduced each case and found no regression relative to the
built-in-only rule (`SpecLint.BuildRecord`, "Threat model").

`Mix.Task.run/2` does nothing when `compile` already ran in the VM (`mix
do compile + spec_lint`, an alias, or a task defined in the project, which
Mix compiles to find it). Before the Milestone 3 review the forced
recompile was then a no-op and the other build's BEAM files were recorded
as the running build's, so the wrong verdict persisted (review, high). The
Mix tasks now re-enable `compile`, `compile.all` and every compiler before
a forced compile, and a forced compile that still reports `:noop` is an
error (exit 2) that writes no record; integration tests cover `mix do
compile + spec_lint`, a task defined in the project, and (with
`SPEC_LINT_OTHER_ELIXIR`) the other compiler.
Reports carry, per BEAM, the digest of the decoded `ExCk` chunk next to
the `beam_lib` MD5, which leaves that chunk out.

Across compiler lines (Milestone 3) the owned applications' artifacts fail
closed three ways. Mix recompiles a project and its dependencies when
`System.version()` changes, as it does between 1.20.4 and 1.21, and the Mix
tasks' build record forces the owned applications. When SpecLint reads BEAM files
without the Mix task (an explicit ebin, `SpecLint.Run` on a build
directory), a record now also names the Elixir version, checker chunk
version and adapter module, and a record of the other line is refused as
`{:other_compiler, ...}` ("compiled by another compiler line ..., whose
artifacts the running adapter cannot read", exit 2); without a record, the
other line's chunk version fails decoding (`unsupported_chunk`, exit 2 in
CI). Baselines record the adapter id, so each line has its own baselines;
another line's baseline is not applied and CI exits 2.

A dependency's stored signatures participate in caller inference. Checking
only its chunk version is insufficient: switching from upstream `648b2a9`
to the fork can retain the upstream dependency and produce a false SL003
on a consumer whose runtime call returns `:ok`. Both builds use v10.
The Mix tasks therefore compile source-backed Mix dependencies in their
actual dependency environment and dependency order, preserving orphan
artifacts so the provenance checks can reject them. Missing or stale
records, or newly compiled dependency modules, force downstream dependencies
and owned consumers to recompile, regardless of code MD5. A checker chunk
can change without changing the code digest. Version 3 invalidated older
owned records whose inference could have used unverified dependencies;
version 4 adds the compiler list and invalidates version 3.
Non-Mix artifacts with Elixir checker chunks and custom dependency compile
commands fail closed; pure Erlang artifacts without checker chunks are
exempt. Dependency records are rechecked after owned compilation.
Without the Mix task (`SpecLint.Run` on explicit ebins), dependency
provenance remains the caller's responsibility. The frozen corpus runner
records exact compiler, source and artifact identities separately.

**Decision:** direct chunk reading from Fable for signatures; the
`Module.ParallelChecker` cache is started only for body analysis and for
the pattern and guard re-check behind `clause_reachable`
(`pattern_diagnostics/4`, which runs the stock `Module.Types.warnings/6`
over the debug info of functions with a clause conflict), and is stopped
in an `after` block.

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
prerequisite blocked or enabled gating. Since Milestone 4 each inferred
clause names its source clause and line when the mapping is exact (section
5.5), and the list ends with a note when it is not.

### 5.5 Source clause mapping (Milestone 4)

`SpecLint.ClauseMapping` maps each stored signature clause back to the
source clauses it came from, only where compiler invariants alone decide
it, from the clause counts of the debug info and the checker chunk:

- **I1** (partition): the checker infers exactly one clause per source
  clause (`infer_local_handler/7`), then drops precise clauses with an
  empty return (1.21 only, `group_clauses/1`) and merges clauses with
  term-equal arguments (`add_inferred/5`) or equal returns differing in one
  argument (`group_clauses_by_return/1`); each source clause ends in at most
  one stored clause and each stored clause has at least one source clause.
- **I2** (order): both merges keep a clause at the position of its first
  member, so stored clause `k`'s smallest source clause precedes stored
  clause `k + 1`'s.

Hence `:single` (one source clause: every stored clause, including the
several clauses of a default-argument wrapper whose body is `{:super,
...}`, comes from it) and `:identity` (as many stored as source clauses:
stored clause `k` is source clause `k`). Everything else is `:ambiguous`.
The invariants were checked in `lib/elixir/lib/module/types.ex` of all
three qualified builds (`c24c235` and `648b2a9` have the same file) and
`elixir_erl:checker_chunk/4`, which stores the grouped signature
unchanged.

A typed mapping (recomputing head types with `Pattern.of_head/8`) was
measured and rejected (`bench/clause_mapping/README.md`): the checker's
fresh-context heads differ from its own (the `subpatterns` leak between
definitions, protocol implementations, gradual upper bounds widened by
subtraction, the redundant-clause path), and the review found exact claims
that are wrong with no compiler warning. Agreement with the replay oracle on
the corpora does not prove exactness.

Findings use the mapping only in their details (`source clause: #k, line
L`) and in `data.source_clause` / `data.clause_mapping`; the issue line
stays the function's first line and the fingerprint is unchanged. Blocking
stays function-wide.

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
  exclude the slice from slice-level `SL001` gating (`conflict`). The
  clause form (`clause_conflict`) is qualified clause by clause under
  `clause_local_qualification` (the default, section 4): an inexact arrow
  only shrinks `D_lo` and only widens `S_hi`, so it cannot fake a contained
  clause or a disjoint return. Exact arrows translate as `fun(args, ret)`.
- Repeated type variables: substitute the bound, record
  `type_variable_correlation`, and treat the return as `hi` only.
- `@opaque` and `@nominal` from other modules: `term()` as `hi`, `none()` as
  `lo`, `opaque_boundary`. Optional structural expansion is a separate flag
  and is labelled in output. The lattice has no nominal support today.
- Recursive types: depth budget, cutoff to `term()` recorded as
  `recursive_cutoff`, never counted as exact.
- Literal map types stay closed; an association with a non-literal key opens
  the map and records a loss. Overlapping associations are validated in
  tests before being called exact. They are read in order, as Dialyzer
  does: the first association for a key wins. A required literal key after
  a domain that covers it is not exact. Dialyzer drops the requirement
  (which it keeps after an earlier literal key), while Elixir code writes
  `%{optional(any()) => any(), year: integer()}` (`Calendar.date()`) to mean
  a map that has an integer `:year`, because keyword keys come last. `hi`
  makes the key optional with both values, `lo` requires it with a value in
  both lower bounds, and `map_key_widened` is recorded. Before the
  Milestone 1 review this was translated as Dialyzer's reading and called
  exact, so the lower bound of `Calendar.date()` was every map.
- Unions are united in Erlang term order of the translated members, so the
  representation, and the fingerprint, does not depend on member order.
- Erlang records stay open tuples tagged with the record name.
- One unsupported construct marks that slice `unsupported`; other slices of
  the same spec are still analysed.

**Adapter notes (Milestone 3).** Translation is the same code on both
compiler lines; it builds descrs only through `SpecLint.Compiler`, so the
line differences it meets are the adapters':

- Recursive types never become recursive descrs on either line: the depth
  budget and re-entry cut them off to `term()` with `recursive_cutoff`.
  1.20 has no recursive nodes (`recursive_types: false` in the
  capabilities), so there is no 1.20-specific loss to record, and the
  translator never asks for the capability.
- Map fields: an optional field reaches `Compiler.closed_map/2` as
  `{key, value, true}` on both lines; V120 writes it as `if_set(value)` and
  names the domain of bitstrings that are not binaries `:bitstring`, and
  hands components back without the `not_set()` marker. The translation
  and its loss records do not change.
- Nominal types: 1.20.4's `Code.Typespec.fetch_types/1` leaves Erlang
  `-nominal` types out, so a remote reference to one translates as
  `unresolved_remote_type` (`term()` above, `none()` below) instead of
  `nominal_boundary`, and `expand_opaque: true` cannot expand it. The
  bounds are the same; only the loss label differs.
- Stored signatures differ in ways that matter for mapping, not for
  translation: 1.20.4 keeps a source clause that always raises as a
  stored clause returning `none()` (1.21 drops it), so stored clause
  indexes shift, and its checker reports some compound impossible guards
  that 1.21 does not (audit-1.20.4.md rows 34 and 35). Findings name the
  stored clause, which the tests pin per adapter.

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

**Decision (body backend experiment, EXPERIMENTS.md):** not adopted.
- **Recall.** Checking each slice's body under its spec domain through the
  `warnings/7` hook gates 1 of the 9 known omissions (`quoted_type/2`), up
  from 0. It reports the same 2 of 9.
- **False positives.** It adds 1 fixture false positive that no diagnostic
  guard removes: an unreachable `case` catch-all.
- **Cost.** Each slice costs about one re-check of the module.
- **What limits it.** The binding limits are helpers inferred under default
  domains, generic `Enum`/`Map` signatures, and translation input
  approximation. A spec domain on the target fixes none of them.
- **Hook artefact.** `warnings/7` returns uncompacted local signatures. A
  consumer must apply the compiler's `group_clauses_by_return/1` before
  applying them, or many-clause functions pass the 16-clause cutoff.

The minimal API proposal is in EXPERIMENTS.md "Minimal compiler API".

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
mix spec_lint --format json > spec-lint.json
mix spec_lint.baseline --output .spec_lint_baseline.json
```

Behaviour:

- The task parses its options first and then invokes `Mix.Task.run("compile")`
  explicitly (no `@requirements`, which would run before `run/1` and make
  `--no-compile` impossible to honour). Compile failures are turned into the
  documented exit 2 with the compiler output shown. The application is not
  started. Compilation runs macros, and compiler checks or type rendering
  may load project modules, invoking generated metadata functions and
  `@on_load` callbacks. This is not a sandbox for untrusted projects.
- `--no-compile` is not in the first release. When added it validates
  artifact freshness against the Mix manifest or marks the run
  artifact-only in the report.
- Umbrella root analyses owned children once and aggregates. `MIX_ENV` and
  `MIX_TARGET` are recorded in output.
- Filters (`--app`, `--module`, paths) mark the run partial. A filter matching
  nothing is an error. A partial run does not check the coverage floor (a
  whole-project property). **Deferred:** path filters are not in the first
  release; `--app` and `--module` are.
- `--analysis signatures|bodies` goes through the configuration, so
  `bodies` fails with the capability message of section 9.1 (exit 2).
- With `--format json` and no `--output`, standard output carries only the
  JSON report: compilation runs under a Mix shell that writes to standard
  error.
- Default scope is exported Elixir functions with specs. Macros, protocol
  dispatch functions, private functions, generated definitions and Erlang
  modules are counted as out of scope in the ledger.
- Profiles: `soundness` gates SL001, SL003 and coverage regressions;
  `review` adds SL006. SL002 is reported in both profiles and gated in
  neither (Phase 0 decision). `--warnings-as-errors` gates every enabled
  warning rule.
- Exit codes: 0 accepted, 1 new gated findings or coverage violation, 2
  incomplete run, unsupported backend, configuration error or internal
  failure. Compile failures surface compiler output and exit 2. A
  configuration file that raises, throws or exits is a configuration error
  (exit 2), and so is an invalid baseline file.

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

Inherited specs. A spec injected by another module's `quote` (a library's
`__using__/1` emitting `@spec`, the definition and `defoverridable`, which
the application then overrides) stays attached to the override; the
Phoenix.View `template_not_found/2` shape gives a correct SL006 that the
application cannot fix. Observed with `Code.Typespec.fetch_specs/1` and the
debug chunk (`test/support/adoption_fixtures.ex`): the injected spec's
annotation is a bare line, the line of the macro call (the `use` line,
neither the definition line nor a line in the library), while a spec written
in the module has `{line, column}`. The BEAM records neither the macro nor
the library, and no `:file`. So the signal is: the spec's annotation has no
column while the function's own definition does (columns were on).
A spec the module evaluates itself from an AST without line metadata
(`Code.string_to_quoted!/1` or a `quote` evaluated in the module body) also
has a bare line, the AST's default line 1, which is not a macro call; a
macro call lies after the module's `defmodule` line (the debug chunk's
module `anno`). `SpecLint.InheritedSpec` reports `{:inherited, line}` only
when the line follows that `defmodule` line; when the definition has no
column (columns off) or the module line is unknown it says nothing.
`quote location: :keep` still yields the bare call line. A finding on such a
spec gets `data.inherited_spec: true`, `data.inherited_spec_line` and a
`note` detail telling the user the spec was not written next to the
definition (baseline it or fix it upstream). Not knowable: the macro's name
or origin module; a spec built by unquoting an AST that keeps its columns is
missed (no false positive). Gating, evidence classes, fingerprints and the
evaluation inventory never read the note.

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
inputs only.

**Cache keys (correction after external review).** `:beam_lib.md5/1` does
not change when only a `@spec` changes (verified: `integer()` to `atom()`
leaves the md5 identical), so a BEAM md5 is not a valid cache key. Any
future cache is keyed by the content of the `Dbgi` and `ExCk` chunks, the
resolved remote type definitions the slice depends on, the tool and adapter
versions, and the configuration digest. Caching remains deferred. A compiler adapter change is recorded separately and triggers
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
  Neither does analysis that did not happen in a complete run: a finding of
  a rule that did not run (`--rules`, `--except`, `:off`), or a finding
  whose slice or module is now `unsupported` or `unavailable`, is not
  stale. Only a slice compared without the finding, or a deleted
  definition, makes a finding stale.

Stale entries are warnings locally and in CI. `mix spec_lint.baseline`
writes a review artifact; ordinary runs never modify it. A partial run cannot
declare unseen entries stale. `mix spec_lint.baseline` rejects filters and
rule selection (`--rules`, `--except`), keeps the entries of rules the
configuration turns off, and refuses to overwrite an output file that is
not a valid baseline. `expires` must be `null` or a `YYYY-MM-DD` date; any
other value makes the baseline invalid (exit 2).

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
identical across two runs on the same inputs. A report already at the
output path is removed when the run starts, and an internal failure after
the per-module analysis (or while rendering) writes none and exits 2, so a
failed or killed run leaves no report that reads as complete. A VM killed
from outside cannot promise exit 2; CI treats a missing report, or one
that is not `complete`, as a failure (Milestone 5, "resource failures").

### 9.1 Implementation notes (Phase 1 product)

These notes record choices the text above left open.

- **Fingerprints.** The spec slice "after named-type expansion" is hashed
  as its translated bounds (`lo`, `hi`) of every argument and of the
  return, through the adapter's canonical `Descr` serialisation
  (`SpecLint.Compiler.canonical/1`), plus the loss records normalised to
  their kind and structural position (named types, union member indexes
  and map association indexes dropped; sorted) and the sorted integer
  intervals. **Decision (post-Phase 1 review):** the annotation-stripped
  spec AST is no longer hashed. It kept type alias names, type variable
  names and union member order, so a cosmetic spec edit turned an
  acknowledged finding into a new gating one. The cost: refinements the
  lattice erases inside a type (`pos_integer()` against
  `non_neg_integer()` in a tuple) do not change the fingerprint.
  `canonical/1` is a structural serialisation of the `Descr` term (maps as
  sorted key/value lists, recursive nodes unfolded to a fixed depth); it
  never prints. The Milestone 1 audit confirmed this, so removing printing
  from classification left every fingerprint and the baseline format
  version unchanged. The slice
  and clause indexes are part of the hash, so reordering spec clauses
  changes the fingerprint. Reordering other functions, changing lines,
  recompiling, renaming a type alias or variable and reordering a union do
  not. Tests cover each case, plus a fresh VM. Reordering a union keeps it
  because translation unites the members in Erlang term order: the
  compiler fuses tuple or map literals that differ in one position as it
  unites them, so `{:ok, binary()} | {:error, :timeout} | {:error, atom()}`
  and its reverse used to be different terms (Milestone 1 review). The
  order of overlapping map associations is part of the meaning (the first
  wins), so reordering them can change the fingerprint.
- **SL008 acknowledgement.** An `SL008` finding is acknowledged by an
  inventory entry with the same subject (MFA, or the module for a
  module-level failure), slice and status. It is not listed among the
  baseline findings.
- **Adapter change.** A baseline whose `adapter` differs from the running
  adapter is not applied. CI exits 2 with a reconciliation message, and
  local runs report it.
- **SL007.** It is off by default. Requesting it, or `analysis: :bodies`,
  exits 2 with a capability message.
- **Clause reachability.** The `clause_conflict` prerequisite is blocked by
  possible shadowing, compiler pattern/guard diagnostics anywhere in the
  function, or unproven source-guard feasibility (section 3.1 step 7).
  Diagnostic lines and `guard_feasibility: "unproven"` are kept in finding
  data. Successful checks leave reachability unchecked; they do not prove
  normal return. A failed check needed for an otherwise eligible SL001 gate
  makes the run incomplete and exits 2 in CI, before baseline decisions,
  under either clause-local setting. It blocks the finding in both settings.
  Disabled SL001 skips its reachability checks. A failure irrelevant to an
  already blocked finding does not turn the run incomplete. Unknown guard
  feasibility is a conservative analysis result, not an operational failure.
  The compiler re-check may load a struct module to read its fields; neither
  it nor witness search invokes target functions.
- **Inexact arrow arguments.** Section 6 excludes a slice with an
  `arrow_polarity` argument from slice-level SL001 gating; the prerequisite
  is `no_arrow_polarity_argument` (the slice form, the clause form with
  `clause_local_qualification: false`, and SL002). Under the default
  clause-local qualification, the clause form uses `clause_contained_in_lo`
  instead (section 4) and keeps the two arrow prerequisites and their
  states in `data.superseded_prerequisites`.
- **Coverage and rule selection.** SL008 is computed in every run. When it
  is not selected, its blocking findings are coverage violations, and the
  inventory acknowledgements are still checked for staleness.
- **`fail_on_regression: false`.** **Decision (post-Phase 1 review):** it
  exempts coverage *regressions* (a slice the inventory lists as compared
  that is now unsupported or unavailable) from gating; they are reported
  with `regression: true`. A slice that was never compared still needs an
  inventory acknowledgement in CI. The asymmetry is deliberate: the option
  exists so that a toolchain change that loses analysis (debug info off, a
  compiler upgrade) does not break CI before the baseline is regenerated,
  while a new coverage gap is reviewed on arrival. The alternative readings
  (a regression needs an acknowledgement, or gates like any unacknowledged
  slice) make the option a no-op, because a regressed slice is stored as
  compared and can never be acknowledged. `--warnings-as-errors` does not
  override it.
- **`expand_opaque: true`** is labelled in the report header, in each
  finding's translation (`translation exact (opaque expanded)`), in the
  inventory entry (`notes`), in the ledger (`slices.expanded`) and in the
  JSON `config`.
- **Ledger reasons.** A compared inventory entry whose obligation is
  `unknown` records why (`unknown_reason`: `top_only`, `near_top`,
  `no_counted_component`, `other`), and the ledger counts them
  (`obligations_unknown_by_reason`), as steps 2 and 8 of section 3.1 ask.
- **SL002 on `no_return()` specs.** SL002 does not report a slice whose
  spec return is empty. That is `SL006`'s case.
- **Spec removal (external review fix).** A slice exists only while its
  `@spec` does, so the inventory alone cannot see a removed spec. Coverage
  compares the baseline inventory with the current exports: a slice listed
  as `compared` whose function is still exported by an analysed module but
  has no spec in scope is an `unanalysed` inventory entry (reason
  `spec_removed`, or `spec_out_of_scope:<reason>`), an `SL008` finding and
  a coverage regression. A function no longer exported (deleted, private,
  now a macro), and a module that is gone, excluded or outside a partial
  run, are not. Regenerating the baseline stores the entry as an
  acknowledged `unanalysed` one, which later runs match like any inventory
  acknowledgement and which goes stale when the spec comes back or the
  function is deleted. The ledger counts these as `lost_analysis`, apart
  from the slices found.
- **Overload removal (second external review).** Section 9's "losing one
  overload while another stays analysed is a violation" is implemented: a
  function that still has specs in scope but fewer clauses than a slice
  index the baseline lists as `compared` gets an `unanalysed` entry with
  reason `spec_clause_removed` for each missing index, which is a
  regression like `spec_removed`. Slices are numbered by position, so the
  missing indexes are the last ones whichever clause was removed; merging
  overloads into one `term()` clause counts too. The first review fix had
  exempted a function with fewer clauses, contradicting section 9.
- **Injected defaults (second external review).** Deleting a user
  definition that overrode a `defoverridable` default injected by `use`
  (`GenServer`'s `handle_info/2`, `child_spec/1`) leaves the default
  exported. It is a deleted definition, not a regression: an export whose
  debug-info definition metadata carries `from_super: false` (the
  compiler's marker for an overridable default that was not overridden,
  `elixir_overridable:store_not_overridden/1`) produces no `unanalysed`
  entry. A user definition that keeps its body but loses its spec is still
  `spec_removed`.
- **Missing BEAM files (second external review).** An ebin that exists
  but lost BEAM files (deleted, or a partial `_build` cache restore) is a
  configuration error (exit 2, `{:error, :missing_beams}`), not a smaller
  project: Mix does not rebuild them, because its manifest says the build
  is up to date, and before this fix every baseline entry of the vanished
  modules was skipped, so CI went green. The build's module list is the
  Elixir compile manifest of a Mix project (read with the pinned
  toolchain's `Mix.Compilers.Elixir.read_manifest/1`), or else the
  `modules` of `<app>.app`, which Mix rewrites only when the ebin's
  modification time is newer than its own (one-second resolution) and so
  can briefly list a deleted module. As a second line, a `compared`
  inventory entry whose slice is absent from the whole inventory (outside
  unavailable modules) is listed as a stale inventory entry in a complete
  run.
- **Gate state in the baseline (second external review).** Fingerprints
  hash the slice's own evidence, not its siblings, so an `SL001` blocked
  by an overlapping overload has the same fingerprint once the overload
  is removed and it gates. Every baseline finding records its blocked
  prerequisites (`"blocked"`). An entry written with a blocked
  prerequisite does not acknowledge an issue of a prerequisite-gated rule
  (`SL001` `conflict`/`clause_conflict`, `SL003`) whose prerequisites are
  now met: the issue is new and the entry is listed under `gate_changed`.
  Entries without the field (earlier baselines) acknowledge as before.
- **Regeneration keeps what was not analysed (second external review).**
  `mix spec_lint.baseline` keeps the previous findings of slices and
  modules that are now `unsupported`, `unavailable` or `unanalysed`, by
  the rule stale detection uses, and the previous `compared` inventory
  entries of modules that are unavailable as a whole. Regenerating while
  debug info is off (the documented `fail_on_regression` workflow) no
  longer drops acknowledgements that come back with the analysis. A kept
  entry whose own adapter is the running one loses its
  `pending_reconciliation` flag, so reverting a toolchain change does not
  turn reviewed acknowledgements into new findings.
- **Baseline paths (second external review).** A baseline path given
  explicitly (`--baseline`, or `baseline:` in `.spec_lint.exs`) must
  exist; a missing one is a configuration error (exit 2), as an explicit
  `--config` is. The default path may be missing. `mix spec_lint.baseline
  --output PATH` runs against `PATH` too, so lost analysis, regressions
  and kept entries all come from the file being written.
- **Per-entry adapter (external review fix).** A baseline finding
  acknowledges an issue only when its own `adapter` (or the file's, when
  it has none) is the running adapter. `mix spec_lint.baseline` keeps the
  entries of rules that are off; when such an entry comes from another
  adapter it is kept with its adapter and `"pending_reconciliation":
  true`, never counts as baselined, is never stale, and is listed under
  `pending_reconciliation` in the decisions, until a regeneration with the
  rule on replaces it.
- **Unsupported sibling overloads (external review fix).** Overlap is
  computed against every sibling slice, unsupported ones included. An
  unsupported sibling makes the overlap `unknown` (which blocks SL001 and
  SL003) unless what can be translated of its arguments, taken as upper
  bounds one position at a time (an untranslatable position is `term()`),
  is disjoint from the slice's domain by the usual tests (upper bounds or
  integer intervals). It is never a certain overlap.
- **Missing build directory (external review fix).** An owned
  application whose ebin directory does not exist is a configuration
  error (exit 2, `SpecLint.Project.check_build_paths/1` returns
  `{:error, :missing_build_path}`). An existing ebin with no module is a
  project with zero specs: exit 0, reported as "0 specs checked".
- **Deep build paths (Milestone 2 review).** BEAM files are decoded from
  their contents (`SpecLint.Beam.chunks/3`), never by file name:
  `beam_lib` turns the name into an atom when it reports an error, and a
  corrupt BEAM under a path over 255 characters crashed the run with
  `system_limit` (exit 1, the gating-findings code) instead of reporting
  an incomplete build (exit 2).
- **Artifacts of another compiler build (Milestone 2 review).** A BEAM
  file whose `SpecLint.BuildRecord` names another build, or that was added
  or changed after the record, is an incomplete build (exit 2), like a
  missing or corrupt one (section 5.2). The Mix tasks recompile with
  `--force` before that can happen. A BEAM file deleted after the record
  is not a record mismatch: it stays a missing BEAM (exit 2), which a
  silent recompile would hide. The report's `artifacts` object gives the
  build digest and the applications whose artifacts are recorded or
  unrecorded, and every `beams` entry an `exck` digest.

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

**Phase 0 outcome (2026-09-28, item 1; details in `EXPERIMENTS.md`).**
The SL002 experiment covered the stdlib and six OSS libraries: jason,
decimal, nimble_options, mime, plug and ecto. That is 2170 spec'd
functions, with no unsupported or unavailable slice and under 1.5 s of
analysis on the stdlib. 107 functions were triaged by hand, and each
verdict was checked by two independent refutation passes.

- **Precision.** All 9 `structured_possible` functions on real code were
  false positives (0/9).
- **Recall.** 9 real omissions were confirmed, and none was
  `structured_possible`. 7 were hidden by top-only inference.
- **Whole-kind filter.** It suppressed 42 functions. 14 were reviewed and
  none was a real omission.
- **Fixtures.** 20 of 20 classes were as expected.

**Decision: SL002 is informational.** It is reported in both profiles and
gated in neither (section 4).

A classifier fix now keeps structure created by subtracting the spec out of
the evidence, as section 3.1 step 5 requires. It reduced the real-code
candidates to 2, both known false positives.

The follow-ups that could change the decision are open questions in section
12: near-top inference, and per-clause evidence under top-only unions. The
second one found 4 stale ecto specs that are SL001-grade.

**Body backend experiment outcome (2026-09-28, Phase 0 item 3 and Phase 3;
details in `EXPERIMENTS.md` "Body backend experiment", reports in
`bench/corpus/reports/body/`).** Each spec slice's body was type-checked
under its spec domain through the `warnings/7` hook on a patched `c24c235`
build (`bench/corpus/warnings7.patch`).

- **Recall.** Gated recall on the 9 known omissions went from 0 to 1
  (`Ecto.Query.Builder.quoted_type/2`, a `clause_conflict`); reported
  recall stayed at 2 of 9. One new real omission was found,
  `Ecto.Changeset.apply_changes/1`, report-only.
- **Precision.** No new false positive on 297 real-code slices (decimal,
  plug, ecto); 1 new fixture false positive after the redundancy guard
  (`display/1`, an unreachable `case` catch-all the checker does not flag).
- **Obligations.** 18 slices moved from `unknown` to `none`, but only 5
  are established (`U(D)` within `S_lo`); the other 13 have inexact spec
  returns and are compatible at available precision only.
- **Cost.** About one module re-check per slice: 1.7 s of body calls over
  decimal, plug and ecto, against 1.2 s for the whole signature analysis.

**Decision: body analysis is not adopted and not qualified further.**
Recall did not improve materially. The 8 misses are blocked by compiler
inference, not by the missing spec domain: 5 are top-only returns through
helpers analysed under default domains or generic `Enum`/`Map` calls, and
2 (`apply_action/2`, `merge_private/2`) are not top-only but leave only an
uncounted component for the same two reasons; input approximation caps 3
of them (`Decimal.compare/2`, `merge_private/2`, `apply_action/2`) at
`possible_input_approximate` whatever the inference does.

**Next investment: compiler inference, then translation, not a body
backend.** In order of the misses each would unblock (at most 4 of the 8
become gateable even with both compiler changes, realistically 3):

1. **Parametric signatures for `Enum.map/2`, `Enum.reduce/3`,
   `Enum.into/2` and `Map.new/1`** (the return follows the fun's return or
   the collectable): `Plug.Conn.Query.decode/4`, `Ecto.Repo.Assoc.query/4`,
   `Ecto.Repo.Preloader.query/7` (top-only today) and
   `Plug.Conn.merge_private/2`.
2. **Call-site-sensitive inference of local helpers and same-module
   callees** (a helper called from a typed context is inferred under that
   context's argument types, not `dynamic()`): `Decimal.compare/2` (the
   `error/4` macro and private `handle_error/4`), `Decimal.cmp/2`
   (delegates to `compare/2`), `Ecto.Changeset.apply_action/2` (through
   `apply_changes/1`).
3. **Recursive definitions inferred to a fixed point** instead of
   `dynamic()` at the self-call: `Ecto.Query.Builder.Join.escape/3`,
   `quoted_type/2`, and `unextract/3` under `Preloader.query/7`. Per-clause
   evidence already isolates these clauses, so this is never the only
   blocker.
4. **Clause reachability per source clause in the checker chunk** (the
   compiler's redundancy verdict): replaces the shadowing approximation
   that over-blocks 23 guarded stdlib clauses, and lets a body run drop the
   return of a clause its domain makes redundant (the `name/1` fixture
   false positive; `display/1`'s unreachable `case` branch is not a clause
   and the checker does not flag it).

The follow-up precision experiment (`bench/corpus/precision_ceiling.md`)
limits the proposed lower-bound work. All 33 contributing stored clause
domains in the nine fixtures extend outside `D_hi`; a larger sound `D_lo`
alone cannot establish their containment. Four slices already have exact
input translation. Preserving more struct or recursive lower-bound
structure may help other cases, but is not a demonstrated recall fix here.
Measure it after domain refinement or a compiler change, and never widen
`D_lo` to represent a required integer literal that the lattice cannot express.

The decision reopens when an upstream build provides item 1 or 2, or a
corpus shows the body run gating at least 3 confirmed omissions the
signature misses with no confirmed false positive.

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
after measurement. **Status:** backend B was measured and not adopted (see
the outcome above); qualifying it waits for the compiler inference
improvements listed there.

## 12. Open questions

- **When SL002 may gate again.** SL002 is informational after Phase 0
  (section 11, `EXPERIMENTS.md`) and after the Phase 1 rerun (2
  candidates reviewed, precision 0 of 2, 0 confirmed omissions). Re-run the
  experiment on the same pinned corpora whenever the classifier or the
  containment rule changes. Promote SL002 to gating in the `review` profile
  only if all three hold: at least 10 candidates are reviewed, precision is
  at least 80%, and at least 3 real omissions are confirmed. Otherwise it
  stays informational.
- **Per-clause evidence under top-only unions.** Resolved by section 3.1
  step 7 (`clause_conflict`, gated as SL001). The Phase 1 rerun found 0
  real-code clause conflicts: the clauses of the known stale specs escape
  the spec domain, so they report as `possible_domain_escape` (2 of the 9
  known omissions are now reported, none gated). The open part is
  real-code precision, which is still 0/0. The first reviewed false
  positive reopens the gating decision.
- **Near-top inference.** Resolved by section 3.1 step 8: both tests
  (term minus finite atoms, and whole coverage of pid, port, reference and
  fun) are applied. 32 stdlib slices are near-top.
- **Static contributing returns.** Resolved: `require_static_return`
  defaults to `false` (Phase 1 rerun). On real code it only relabels the
  two refuted `Calendar.ISO` candidates, and on the fixtures it drops 2 of
  the 4 clause-conflict detections (`size_of/1`, `stale/1`) and 3 of the 4
  `structured_possible` detections. The option stays configurable.
- **Clause reachability.** The `clause_conflict` prerequisite "the compiler
  did not flag the clause unreachable" is not in the checker chunk. It is
  decided from the stored clause domains and from the compiler's type
  checker re-run over debug info (section 3.1 step 7). The first
  over-blocks guarded clauses: on the stdlib 23 contributing clauses (22
  functions) are possibly shadowed, none of them a conflict. The second
  blocks per function, not per clause: stored clauses are mapped to source
  clauses only in the structural cases of section 5.5, and the checker's
  diagnostics are attributed to lines, not to clauses. On the fifteen
  corpora no clause conflict is blocked by a diagnostic (all nine are
  gated), so per-clause blocking would change no gate there. The additional bounded source-guard witness
  check conservatively blocks unsupported or unwitnessed guarded functions,
  including contradictions the compiler does not diagnose. It is not a
  general reachability solver and does not prove that a body returns normally.
  A versioned upstream per-source-clause verdict and source-to-stored mapping
  would reduce over-blocking and let a finding name its source clause and line;
  that verdict must distinguish unknown from proven reachability.
- **Containment against typed struct fields.** A struct pattern leaves
  fields `term()`, so any function whose spec takes a struct with typed
  fields is `domain_escape`. That makes `structured_possible` unreachable
  for typical struct APIs (decimal, plug, ecto). The open question is
  whether containment should ignore struct fields the clause never reads.
- Whether overlapping overloads follow Erlang's intersection reading or the
  Elixir checker's union-of-matching-clauses reading; the choice changes
  SL001 on those functions.
- Behaviour callback conformance and missing-spec style checks are separate
  future rules; whether they belong in this package or in Credo.
- Whether dependencies should ever be lint targets (`--include-deps`), given
  consumers cannot fix them.
