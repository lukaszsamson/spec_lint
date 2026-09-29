# Phase 3 review of 0cc9c50

Reviewed 2026-09-29. The production tree was not modified. The pre-existing
untracked `UPSTREAM_BUGS.txt` remains untouched.

## Verdict

The clause-local bounds argument and the demonstrated Ash gate are useful,
and the compiler counterexamples are the right direction for recall work.
However, fix two reachability issues before treating this version as a reliable
CI gate or widening its gating policy. The new compiler diagnostic check
reduces false positives; it does not establish reachability.

Independent validation: all 311 tests passed; full Credo (70 checks), formatting,
Dialyzer (zero errors), and the self CI check passed. The self check compared
276 slices and exited 0. Extra review probes below demonstrate cases outside
that suite.

## P1: a simple impossible compound guard still gates

Relevant implementation: `lib/spec_lint/rules/return_conflict.ex:225`,
`lib/spec_lint/reachability.ex:88`.

Minimal source:

```elixir
defmodule CompoundDead do
  @spec g(:a | :b) :: :ok
  def g(:b = x) when is_integer(x) and is_atom(x), do: {:error, :bad}
  def g(x) when is_atom(x), do: :ok
end
```

Both possible spec inputs return `:ok`. The first clause cannot execute:
its pattern binds `x` to `:b`, which is not an integer. Nevertheless, on the
qualified compiler the compound guard produces no diagnostic, its conflicting
stored clause remains, and SpecLint emits a gated SL001 `clause_conflict`
with `clause_reachable: unchecked`. The run exits 1 in both review and
soundness profiles. The same happens when the compound predicate is wrapped
in `defguardp`. A direct or macro-wrapped *single* `is_integer(x)` guard is
correctly diagnosed and blocked. Therefore this is not generally a macro
metadata problem; the compound expression is enough.

Reproduction (compile the source above to `$PROBE/ebin`):

```sh
elixirc -o "$PROBE/ebin" "$PROBE/probe.ex"
elixir -pa "$PROBE/ebin" -e 'IO.inspect({CompoundDead.g(:a), CompoundDead.g(:b)})'
elixir -pa _build/dev/lib/spec_lint/ebin bench/run_on_ebin.exs -- \
  --ebin "$PROBE/ebin" --root "$PROBE" --ci --profile soundness \
  --format json --output "$PROBE/report.json"
```

The actual review used two modules, direct and macro versions, producing two
false gates. Artifacts are in `/tmp/spec-lint-phase3-compound/`. This is an
existing limitation of the shared clause policy, not evidence against the
new `D_lo`/`S_hi` bounds proof. Disabling clause-local qualification does not
solve the underlying issue for arrow-free specs.

Required follow-up: add both versions plus their single-predicate controls to
the regression suite. Investigate guard feasibility using compiler-internal
results rather than only emitted diagnostics. If feasibility cannot be
established for a guarded conflicting clause, retain the finding but avoid
presenting it as a qualified CI contradiction. Preserve true positives for
ordinary guarded and unguarded clauses. Simply blocking this exact syntactic
expression or checking only for more warning variants is not a general fix.

This also gives a small compiler diagnostic/precision investigation candidate;
reproduce on unmodified current upstream before assigning it upstream. It is
not a demonstrated compiler soundness violation.

## P2: reachability-check failures do not make the run incomplete

Relevant implementation: `lib/spec_lint/run.ex:372`,
`lib/spec_lint/run.ex:401`, `lib/spec_lint/rules/return_conflict.ex:227`.

The finish path checks analysis failures and unsupported chunks, but not errors
in `run.reachability`. Injecting an adapter result
`{:error, {:checker_failed, "injected review failure"}}` produced:

- Qualification on: `completion: :complete`, no completion reasons, exit 0;
  the findings merely have a blocked prerequisite and an unavailable note.
- Qualification off: `completion: :complete`, exit 1; known dead single-guard
  clauses gate because the unavailable check becomes `:unchecked`.

The latter behavior is explicitly asserted in the current clause-local tests;
it is a policy defect to change, not a flaky test. The fault-injection adapter
forwarded all other operations to `Compiler.V121`. This is an injected failure
case, not a claim that any committed OSS scan suffered a checker failure.
Script: `/tmp/spec-lint-phase3-review/check_failure.exs`.

Required follow-up: a failed safety check required for an otherwise eligible
SL001 gate must be observable as incomplete analysis and exit 2 in CI, in both
configurations. Preserve the findings and the failure reason. Distinguish a
successful check with no diagnostic from an unavailable/failed check, and do
not let baseline acknowledgements turn this failure into a clean run. Avoid
forcing such checks when the rule is disabled or their result is irrelevant.

## What the evidence does and does not establish

- The new bound qualification adds one witnessed true gate, Ash.Page.page_opts/1.
  Its argument is sound assuming the translated bounds are sound. It does not
  prove that a conflicting stored clause is executable.
- The seven Absinthe gates concern one function and one repeated
  source_location-default mismatch. Together with Oban and Ash, this is three
  distinct gated functions, not nine independent defect families.
- The fresh holdouts had no arrow-blocked clause conflicts for the new rule to
  unlock. Their unchanged results are useful regression evidence, but do not
  independently measure precision on newly qualified holdout cases.
- "Zero false positives in the measured OSS corpus" remains a statement about
  that reviewed sample. It is not a general guarantee; the compound-guard
  counterexample above now belongs in the known-negative corpus.
- The Phase 3 summary misnames one integration result: the five integration
  omissions are read/2, read_one/2, read_first/2, page/2 and Policy.solve/1.
  refute_has_error/3 already had a direct witness. Query.apply_to/3 remains
  unproved within its declared input domain.
- The Ash input predicates intentionally check only part of the nested types.
  Keep their stated limits and the actual repaired inputs alongside any
  ground-truth claims; passing a hand-written predicate alone is not proof
  of membership in the complete declared type.

## Recommended next steps

1. Make a small CI-correctness milestone first: fix the two findings, add
   adversarial guard cases and checker-failure tests, and rerun all existing
   corpora. Acceptance: no gate for the impossible clauses; required checker
   failures exit 2; the reviewed Oban/Ash/Absinthe gates remain explained.
   Track any conservative loss of gates explicitly rather than hiding it.

2. Keep the intended clause-local policy after hardening. Its bounds argument
   is better than blanket arrow exclusions; more relaxation of classifier
   prerequisites is not the next recall lever.

3. Run a narrowly scoped compiler experiment on helper return relationships.
   Start from compiler_counterexamples/helper_insensitivity.ex and compare
   pinned unpatched, experimental, and current-upstream behavior. Prefer
   bounded specialization or parametric summaries over unrestricted repeated
   body analysis. Include recursion, raising paths, multiple call domains,
   unions and performance controls. Do not silently make a new compiler build
   pass the existing adapter's qualification.

4. Treat Enum.map result precision as a separate experiment. The comprehension
   control already shows that better list-element inference alone does not
   make SpecLint detect that example. Measure the compiler and list-evidence
   bottlenecks separately; do not promise recall from a more precise signature.

5. Before either optimization, freeze a new validation cohort. Ash, Nx,
   Absinthe and Tesla are now observed. Measure new independently witnessed
   detections by function and defect family, unknown reasons, false gates,
   incomplete runs and compilation/analysis time. A reasonable next-milestone
   target is new witnessed detections in at least two independent real
   functions, with no known false gates; not simply fewer unknown counters.

6. Report the small library typespec fixes and discuss the standalone compiler
   examples upstream, after checking current revisions. Do not file speculative
   runtime bugs or claim that the compiler promises to validate these specs.

## Default treatment of internal validators and constructors

My recommendation is to keep explicit exported specs in scope even when
`@doc false`. Documentation visibility does not change the type contract.
Likewise, Absinthe's default nil is a normal constructor result, so the
corresponding type should admit it if it is intentional. Blanket constructor
or internal-function exemptions would hide useful findings.

Explain those cases clearly, and use the existing reasoned baseline mechanism
for intentional debt. Consider narrower scope controls only after actual user
feedback, and record exclusions in the coverage ledger. This product choice
is separate from the false-gate defects above: those must not be solved by
asking users to baseline incorrect analysis.
