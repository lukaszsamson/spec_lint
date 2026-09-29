# SpecLint 0.1.0: experimental release verdict

**Current verdict: requalification pending.** Release campaigns 1 and 2
qualified historical tool revisions `06b7496` and `58fe1dd`. Their figures
and exit-criterion decisions below are retained as historical evidence,
and do not certify the current tree after compiler gating, reachability
and artifact-provenance hardening.

Upstream `648b2a9` is now **diagnostic-only**: its mixed list/bitstring
`for ... into:` inference can gate a correct spec, including through
callers. All findings have `gate: false`; the report is `incomplete`.
`--ci` and `--warnings-as-errors` exit 2, a local run exits 0, and a baseline
cannot waive the restriction or be written. `c24c235` and 1.20.4 remain CI
candidates pending current-tree requalification. Build-record version 3
requires per-module production evidence and rejects unverified orphan
BEAMs without deleting them. Only built-in Mix compiler pipelines are
supported; custom compiler configurations, including umbrella children,
are refused with exit 2. Dependency provenance is also required before
consumer compilation; the same checker chunk version does not establish
that two compiler builds inferred the same signatures. Custom compiler-bearing
Mix dependencies, including `file_system` in development environments, are
unsupported. The runtime self-check uses `MIX_ENV=prod`; the development
checkout with all lint-tool dependencies is refused.

The historical campaigns observed no gated false positives on fifteen
corpora, detected 3 of 18 witnessed omission families, and gave no verdict
on roughly three quarters of compared specs. Read “What is not claimed”
before relying on a clean run.

| | |
| --- | --- |
| Tool | `58fe1ddf34d23d22d3048cceb09a2d60e8d9342e`, `source_sha256` `26c90fa8...948a9eb` |
| Evaluation | frozen inventory version 2 (`bench/evaluation/INVENTORY.md`, `5753b08`; version 1 `e464905`) |
| Campaigns | 1: `bench/corpus/reports/release-1/` (tool `06b7496`); 2: `bench/corpus/reports/release-2/` (tool `58fe1dd`, byte-identical product reports) |
| Machine | Apple M2 Pro, 12 cores, 32 GB, macOS 26.7, Erlang/OTP 28.5.0.1 |
| Date | 2026-09-29 |

## Historical exit criteria (release campaigns 1 and 2)

From `NEXT_STEPS.md`, Milestone 5.

| Criterion | Verdict | Evidence |
| --- | --- | --- |
| Freeze the executable witnesses, omission families, recall denominator and holdout procedure before measuring; audit the "six witnessed Ash misses"; do not count the seven Absinthe gates as seven families | **met** | Version 1 (`e464905`) frozen before campaign 1; version 2 (`5753b08`) is the documented change the review required (F18, self-checking holdout witnesses). The Ash audit: 7 witnessed families (1 gated, 6 reported), not "six misses". Absinthe's seven gates are one family (F16). `test/spec_lint/evaluation_inventory_test.exs` resolves every witness reference. |
| Count struct-default violations separately without changing their policy | **met** | 7 findings per compiler, all seven `Absinthe.Blueprint.Input.parse/1` gates (`release-*/*/struct_defaults.json`); policy unchanged. |
| Re-run all known gates and independently refute every new or changed gate | **met** | Campaign 1: 27 gates (9 per compiler, 3 functions), none new, all `changed` in diagnostic data only (`release-1/gates.json`); each function survived two independent refutation attempts (`release-1/refutation.json`). Campaign 2: all 27 `unchanged` (`release-2/gates.json`). |
| Both supported adapters meet correctness | **met** | Qualification of the frozen tree under `c24c235`, `648b2a9` and 1.20.4 (`release-2/qualification/`: format, strict Credo, 468/468/471 tests with the other compiler and a 1.19 compiler named, Dialyzer, self-check). Replay complete and reproducible: campaign 2 equals campaign 1 byte for byte on all 45 product reports. **0 gated false positives.** Detection measured against the frozen inventory (below). |
| Both supported adapters meet runtime budgets | **met** | Campaign 2, measured against `bench/corpus/budgets.json` as frozen from campaign 1: every corpus within its wall-time and peak-RSS budget under every compiler (`release-2/*/*.resources.json`). |
| Installation and upgrade workflows pass | **met** | `test/integration/release/` (18 tests: path, git and umbrella installation, the baseline workflow, compiler and SpecLint upgrades, incomplete builds, the 1.19 refusal) passes under the three compilers, none skipped. |
| The README publishes the support matrix, unknown-obligation counts and gating limitations | **met** | `README.md`, "Requirements" (matrix), "What a result means" (unknown obligations per compiler, recall, gated false positives), "Rules" (gating prerequisites); `test/spec_lint/release_docs_test.exs` checks the figures against the reports and that no placeholder is left. |
| Resource failures leave no successful result | **met** | `test/integration/resource_failure_test.exs`: an analysis crash (exit 2, report `incomplete`), an exception, an exit or a crashed linked process after the analysis (exit 2, no report), a crashed reachability check (report `incomplete`), a VM killed during the analysis (no report). CI must treat a missing or non-`complete` report as a failure; the corpus runner rejects a killed run's report. |

## Current compiler policy

| Elixir build | Adapter id | Checker chunk | Status |
| --- | --- | --- | --- |
| 1.21.0-dev `648b2a9`, upstream `elixir-lang/elixir` | `1.21.0-dev+648b2a9` | `elixir_checker_v10` | diagnostic-only; all gates disabled; known compiler defect: `for ... into:` with a list-or-bitstring collectable stores an unsound signature, which previously could make SpecLint gate a correct spec (audit row 19) |
| 1.21.0-dev `c24c235`, fork `lukaszsamson/elixir` | `1.21.0-dev+c24c235` | `elixir_checker_v10` | CI candidate; current requalification pending (fixes the `for ... into:` defect) |
| 1.20.4 (`759443e`, the precompiled release) | `1.20.4+759443e` | `elixir_checker_v8` | CI candidate; current requalification pending, with its own baselines |
| 1.19 and earlier, 1.20.0-1.20.3, other 1.20.x or 1.21 builds | none | | **unsupported**: the task refuses itself (exit 2 with `--ci`; checked on 1.19.4) |

Erlang/OTP 28 (1.20.4 also on OTP 29). A baseline is per compiler adapter.
The two 1.21 builds give the same fingerprints on the benchmark corpora;
1.20.4 and 1.21 differ wherever a map or struct type is involved.

## Historical numbers per adapter

Fifteen corpora (the Elixir standard library, jason, decimal,
nimble_options, mime, plug, ecto, req, broadway, oban, phoenix_live_view,
ash, nx, absinthe, tesla), default configuration. Campaigns 1 and 2 give
identical historical reports. Their `648b2a9` gates predate its current
diagnostic-only restriction.

| | 1.21 `c24c235` | 1.21 `648b2a9` | 1.20.4 |
| --- | ---: | ---: | ---: |
| Compared spec slices | 4,204 | 4,204 | 4,170 |
| Obligations established | 841 | 841 | 830 |
| Compatible after approximation | 193 | 193 | 186 |
| Possible mismatch | 57 | 57 | 59 |
| Whole-slice conflict | 0 | 0 | 0 |
| **Unknown** | **3,113 (74.0%)** | **3,113 (74.0%)** | **3,095 (74.2%)** |
| unknown: `top_only` / `near_top` / `no_counted_component` / `other` | 2,220 / 54 / 839 / 0 | 2,220 / 54 / 839 / 0 | 2,210 / 51 / 834 / 0 |
| Findings (SL001 / SL002) | 63 (9 / 54) | 63 (9 / 54) | 65 (9 / 56) |
| **Gates** | **9** | **9** | **9** |
| Gated false positives after refutation | 0 | 0 | 0 |
| Struct-default findings (all gated) | 7 | 7 | 7 |
| Inventory v2 (18 families): gated / reported / silent | **3 / 8 / 7** | **3 / 8 / 7** | **3 / 8 / 7** |
| `return_value` families (15): gated / reported / silent | 2 / 8 / 5 | 2 / 8 / 5 | 2 / 8 / 5 |
| Inventory v1 (17 families): gated / reported / silent | 3 / 7 / 7 | 3 / 7 / 7 | 3 / 7 / 7 |

The 9 gates per compiler are clause conflicts on three functions:
`Oban.Registry.via/3` (F09), `Ash.Page.page_opts/1` (F10) and the seven
clauses of `Absinthe.Blueprint.Input.parse/1` (F16, struct fields left at
their default `nil`). All three are witnessed omissions: each gate is a
true positive. Their slices count as possible mismatches in the ledger;
no slice's whole inferred return is disjoint from its spec. Families
(`bench/evaluation/INVENTORY.md`, "Current detection"): gated F09, F10,
F16; reported (SL002, never gating) F05, F06, F11-F15, F18; silent F01-F04,
F07, F08 (the original eight hand-found omissions except the two stale
Ecto specs) and F17.

## Budgets

`bench/corpus/budgets.json`, enforced by `bench/corpus/run.sh` (a missing
file or corpus entry is an error; only `SPEC_LINT_BUDGETS=none` disables
it) and by `test/spec_lint/corpus_report_test.exs` over every committed
measurement. Derived after campaign 1 (wall = max(5 s, 1.5 x its maximum),
peak RSS = max(256 MiB, 1.3 x its maximum)), so they are regression
thresholds for this machine class, not targets declared in advance.
Campaign 2 is the first measurement against them.

| Corpus | Budget | Campaign 2 (c24c235; 648b2a9; 1.20.4) |
| --- | --- | --- |
| absinthe | 90 s, 8,256 MiB | 57.2; 57.1; 58.0 s; 5,774-6,080 MiB |
| ash | 10 s, 448 MiB | 3.4-3.9 s; 307-320 MiB |
| stdlib | 5 s, 576 MiB | 1.4 s; 422-445 MiB |
| the other twelve | 5 s, 256 MiB | 0.5-1.0 s; 120-170 MiB |

Absinthe's whole product run (VM start included) is under the Milestone 1
target of 60 s on every compiler; its peak memory is about 6 GB.

## Known limitations

- **Low recall on real omissions.** 3 of 18 witnessed omission families
  gate (2 of 15 where the returned value itself is undeclared); 8 more are
  reported by SL002, which never fails CI; 7 are silent. The binding
  limits are in the compiler's inference (private helpers inferred under
  default domains, `dynamic()` results of generic `Enum`/`Map` functions)
  and in translation (integer refinements, opaque and recursive types).
- **Most slices get no verdict.** 74% of compared slices are unknown
  obligations, mostly because the inferred return is `term()` or
  `dynamic()`.
- **Compiler internals.** SpecLint reads `@moduledoc false` compiler
  internals (`Module.Types.Descr`, the `ExCk` chunk); every other compiler
  build is refused, and each new Elixir build needs a new qualification.
  The compiler's own defects pass through (the `for ... into:` defect of
  `648b2a9`).
- **Clause mapping and reachability are approximated.** Per-clause
  findings name the stored signature clause; the source clause is named
  only where the compiler's grouping forces it. A pattern or guard
  diagnostic anywhere in a function blocks every clause conflict of it,
  and guarded clauses need a bounded feasibility witness.
- **Not gated by design**: SL002, overlapping overloads, function types
  that translate inexactly, and anything behind an unmet prerequisite;
  `--explain` shows which.
- **Budgets are machine-specific** and a killed VM (a CI timeout, the
  out-of-memory killer) cannot promise exit 2: CI must require a report
  whose `completion.status` is `complete`.
- **Single-machine measurements**: all runtime figures are from one
  machine; OTP releases other than 28 (and 29 for 1.20.4) are untested.

## What is not claimed

- **Not that a clean run means correct specs.** No finding is not a
  proof: an unknown obligation, a silent omission class or an ungated
  finding all look like "0 gating findings".
- **Not a recall figure for arbitrary code.** The 3 of 18 is on a frozen,
  hand-built inventory drawn from these corpora; it is not an estimate of
  the fraction of real spec bugs found in other projects.
- **Not a general false-positive rate.** 0 false positives among 27 gates
  on three functions is too few gates to bound the rate; the first
  confirmed false positive reopens the gating decision of its evidence
  class.
- **Not that a conflict's return happens.** A gate says a normal return
  *would be* outside the spec; inference over-approximates and never
  proves that a return occurs.
- **Not support for any compiler outside the matrix**, nor stability of
  fingerprints across compiler lines or SpecLint versions (baselines are
  regenerated deliberately).
- **Not the body backend** (SL007, `--analysis bodies`): unavailable.
- **Nothing upstream.** The Milestone 6 package (`bench/upstream/`) is
  prepared, not filed; no compiler change is claimed.

## Review of campaign 1

The Milestone 5 review of campaign 1 (`STATUS.md`, "Milestone 5 review")
raised 18 findings: two high (the README's unfilled placeholders, and
`Ash.Query.apply_to/3` wrongly excluded from the inventory), six medium
and ten low. All were fixed with regression tests or documented; none
changed a report. The fixes changed `lib/` and the corpus tooling, which
is why the release is of the new freeze `58fe1dd` and campaign 2 exists.
