# SpecLint status

Date 2026-09-30. `DESIGN.md` is the authoritative design,
`EXPERIMENTS.md` holds measurements, and `README.md` is the user guide.
Phase 4 follows the review of the Phase 3 implementation at `0cc9c50`;
previous results below are historical and are superseded where noted.

## Post-release review hardening completed (2026-09-30)

Implementation `1bb9594` is qualified for experimental CI on the exact
c24c235 fork and 1.20.4 release builds. Full quality gates passed with
497 / 499 tests, strict Credo, format, Dialyzer and production self-checks
(419 specs, zero findings). The final thirty-run campaign passed every
frozen budget and preserved every product report byte for byte. Evidence:
[quality](bench/corpus/toolchain/quality-1bb9594/README.md),
[campaign](bench/corpus/reports/hardening-2/README.md), and
[current verdict](RELEASE.md).

Adversarial review closed a real false-gate path: cached dependencies built
by an unsound compiler could contaminate a consumer compiled by a qualified
one. Build-record v3 now binds dependency artifacts and production events;
checker-only changes force downstream rebuilding. Unverified orphan outputs,
custom compiler pipelines and stale or mixed campaign evidence fail closed.
Both built-in lexer/parser generator orders are accepted. Reachability
checks retain full-module context. Upstream 648b2a9 is diagnostic-only:
its unsound stored signatures propagate to callers, so all gates are disabled
and CI exits 2, regardless of baseline acknowledgements.

Linux qualification has a narrower scope than macOS; see the explicit
full-suite/targeted-check distinction and the failed 6 GiB Absinthe stress
run in [Linux results](bench/corpus/toolchain/linux-results.md). The complete
macOS Absinthe replays took 75.71 / 67.99 seconds within the frozen 90-second
budget, not the earlier 60-second aspiration.

Publication is authorized at `lukaszsamson/spec_lint` under Apache-2.0.
Elixir-derived code carries source and modification notices. No Hex release
or new upstream issue has been published as part of this qualification.
The original objective remains open: 3 / 8 / 7 gated / additionally reported /
silent families out of 18. Future priorities are public-task adoption with
custom dependency compilers, lower retained memory, and compiler inference
work judged on independently witnessed real omissions.

## Milestone 5 delivered: experimental release (2026-09-29)

Verdict in `RELEASE.md`: **release as experimental**; every Milestone 5
exit criterion is met on `c24c235`, `648b2a9` and 1.20.4. The released
tree is `58fe1dd` (`source_sha256` `26c90fa8...948a9eb`), replayed as
release campaign 2 (`bench/corpus/reports/release-2/README.md`).

- **Refutation of campaign 1's gates** (`release-1/refutation.json`): the
  3 gated functions (27 gates: `Absinthe.Blueprint.Input.parse/1` x7,
  `Ash.Page.page_opts/1`, `Oban.Registry.via/3`, on each compiler)
  survived two independent attempts each. 0 gated false positives, so no
  evidence class needed downgrading and no corpus a re-run for that.
- **Campaign 2** (tool `58fe1dd`, frozen budgets): every product report
  byte-identical to campaign 1 on all three compilers; 27 gates, all
  unchanged; every corpus within budget (Absinthe 57-58 s, 5,774-6,080 MiB);
  struct defaults 7 per compiler; qualification 468/468/471 tests (with
  the other compiler and 1.19.4 named, none skipped), Dialyzer 0 errors,
  self-check 408 slices, exit 0.
- **Figures** (both campaigns, per compiler 1.21 / 1.20.4): 4,204 / 4,170
  compared slices, 3,113 / 3,095 unknown obligations (74.0% / 74.2%;
  `top_only` 2,220 / 2,210, `near_top` 54 / 51, `no_counted_component`
  839 / 834), 63 / 65 findings, 9 gates. Inventory version 2: 3 gated, 8
  reported, 7 silent of 18 families (`return_value` 2, 8, 5 of 15);
  version 1: 3, 7, 7 of 17.
- **README** placeholders filled with these figures; the frozen criterion
  for the missing-return objective is in `NEXT_STEPS.md` (M5).
- **M6** prepared, not submitted: `bench/upstream/` (`58fe1dd`), nine
  items, all reproducing on upstream `648b2a9`.

Commits: `9f42022` (crash handling), `0cd5d11` (fail-closed tooling),
`5753b08` (inventory version 2), `08d96f9` (installation and upgrade
tests), `58fe1dd` (upstream package), `2f2580c` (campaign 2 reports and
refutation), then this verdict.

### Milestone 5 review: eighteen findings

| # | Sev. | Finding | Outcome |
| --- | --- | --- | --- |
| 1 | high | README committed with unfilled `{{...}}` placeholders (unknown counts, recall, gated false positives) | **fixed**: filled from the release reports, note deleted; `ReleaseDocsTest` fails on `{{` and checks the ledger figures against the reports |
| 2 | high | `Ash.Query.apply_to/3` (C01) wrongly excluded: in-domain filters return the undeclared `{:error, _}` | **fixed**: inventory version 2 (`5753b08`), F18 with two witnesses and a control; denominator 18; Ash audit and detection recomputed |
| 3 | medium | `06b7496` swept in the installation agent's README draft | **documented** (release-1 README, here); the draft was finished with the tests (`08d96f9`) and this verdict; later commits stage explicit paths |
| 4 | medium | README cited `test/integration/release/`, which was untracked | **fixed**: committed in `08d96f9` after the gates passed under all three compilers with both compiler variables set |
| 5 | medium | `run.sh` silently skipped budget checks for a missing file or corpus entry | **fixed** (`0cd5d11`): exit 2 before running; only `none` disables; tested |
| 6 | medium | an exit or a crashed linked process (reachability task) ended the run with status 1, no report | **fixed** (`9f42022`): `SpecLint.Isolated` (monitored, unlinked), exits caught and trapped in the guarded stage, `internal!/1` and `run_on_ebin.exs` catch exits; two integration tests fail before the fix |
| 7 | medium | `gate_diff.sh` passed with a missing corpus report, shortening the refutation list | **fixed** (`0cd5d11`): expected corpora from both directories; exit 2 on a missing or incomplete report or directory; tested |
| 8 | medium | (duplicate of 1) placeholders in the committed README | **fixed** with 1 |
| 9 | low | budgets derived from the run they certify | **documented** (release-1 README, `RELEASE.md`); campaign 2 is measured against them as frozen. Absinthe's budget is not tightened to 60 s: the measured maximum (58.0 s) would leave 3% headroom for noise; the 60 s target is reported as met separately |
| 10 | low | F10-F12 witness references did not resolve; no in-domain flag | **fixed** in version 2: case ids, domain and return predicates in `holdout_witnesses.exs`, F11 control and line citation; `EvaluationInventoryTest` resolves every reference |
| 11 | low | any finding on a family's MFA counts, even an unrelated one | **partly fixed**: `detection.exs` lists every counted finding (`matched`); all current matches contain the witnessed value (checked, INVENTORY.md "Counting"). The rule itself is unchanged in version 2: changing it now would change a frozen definition without a measured need; a later version may require the match |
| 12 | low | no committed detection for campaign 1; no provenance revision check | **fixed**: `release-1/detection_v1.json` and `detection_v2.json`; `detection.exs` refuses a report whose provenance revision is not the pin |
| 13 | low | `run.sh` kept a complete-looking report of a VM killed after its write | **fixed** (`0cd5d11`): a signalled run (time's own message) or an exit/report mismatch keeps the report as `NAME.spec_lint.rejected.json` and records no measurement; tested with a VM killed after the write |
| 14 | low | `compare_replay.sh` was vacuously `all_unchanged` for empty or missing directories | **fixed** (`0cd5d11`), tested |
| 15 | low | `compare_lines.sh` and `struct_defaults.exs` skipped missing reports and counted incomplete ones | **fixed** (`0cd5d11`); `compare_lines.sh` is tested; `struct_defaults.exs` was checked by hand (empty directory and a provenance without its report: exit 2) and has no automated test because it needs `mix run` under a qualified compiler in a subprocess |
| 16 | low | `bench/upstream/README.md` named a session scratch path | **fixed** (`58fe1dd`); `ReleaseDocsTest` rejects such paths in the release documents |
| 17 | low | `holdout2_baseline.md` named a home directory | **fixed** (`58fe1dd`) |
| 18 | low | `SPEC_LINT_UNSUPPORTED_ELIXIR` undocumented; stale test counts | **fixed**: README "Development" documents both compiler variables; counts refreshed (468/468/471) |

## Milestone 5: release campaign 1, correctness and runtime (2026-09-29)

Frozen tool `06b7496` (`source_sha256` `b039ce7d...8edded`), after the
frozen evaluation inventory (`e464905`). Report:
`bench/corpus/reports/release-1/README.md`.

- **Resource failures** (`06b7496`): an exception after the per-module
  analysis, or while rendering, is an internal failure (exit 2, no report)
  instead of Mix's exit 1; `--output` removes an earlier report before the
  run. Integration tests: analysis crash (exit 2, report `incomplete`),
  exception after the analysis (exit 2, no report), VM killed during the
  analysis (no report). An OOM-killed VM cannot promise exit 2: CI treats
  a missing or non-`complete` report as failure (README, "Exit status").
  `compare_replay.sh` exits 2 on a missing, truncated or incomplete report;
  `run.sh` removes a corpus's earlier outputs first.
- **Toolchains.** Both 1.21 compilers rebuilt from fresh clones with
  `build_elixir.sh`; 648b2a9 reproduces its recorded identity. The fresh
  `c24c235` differs from `~/elixir` in two stdlib checker chunks (`URI`,
  `Logger.Backends.Console`), which equal 648b2a9's: `~/elixir` is not a
  clean build, and the Milestone 2 attribution of those two differences to
  the compiler change is corrected (only `IEx.Autocomplete` remains).
- **Qualification** of the frozen tree under `c24c235`, `648b2a9` and
  1.20.4: formatting, strict Credo, tests (439/439/442 passed), the
  cross-compiler test, Dialyzer and the self-check (407 slices, exit 0) pass.
- **Replay** of the fifteen corpora under the three compilers: complete,
  4,204/4,204/4,170 slices, 3,113/3,113/3,095 unknown obligations, 63/63/65
  findings, 9 gates each; ledgers, gates, exit codes and fingerprints equal
  the previous reports of each adapter. A second run is byte-identical.
- **Runtime** (`/usr/bin/time -l`, M2 Pro): Absinthe 53-58 s and 6.0-6.3 GB
  peak RSS on every compiler; every other corpus under 4 s and 450 MB.
  Budgets in `bench/corpus/budgets.json` (Absinthe 90 s and 8,256 MiB),
  enforced by `run.sh` and a test; both runs are within them.
- **Struct defaults** (counted, no policy change): 7 findings per adapter,
  all seven `Absinthe.Blueprint.Input.parse/1` gates (F16); 2 of the 9
  gates are not struct defaults.
- **Gates for refutation** (`release-1/gates.json`): 27 (9 per adapter),
  all `changed` in `data` only (Milestone 4 source-clause fields), none new.

## Milestone 4 delivered: source-clause mapping, structural classes adopted (2026-09-29)

Decision (`bench/clause_mapping/README.md`, which is the report; DESIGN.md
5.5): adopt only the two mapping classes the compiler's clause grouping
forces without any type, and keep every other function ambiguous.

- **Invariants.** `infer_local_handler/7` infers one clause per source
  clause in order; `group_clauses/1` (1.21 only) drops, and `add_inferred/5`
  and `group_clauses_by_return/1` merge into the first earlier member (I1:
  partition; I2: first members stay ordered). Checked in `types.ex` of
  `c24c235`, `648b2a9` (identical file) and 1.20.4, and in
  `elixir_erl:checker_chunk/4`. Hence `:single` (one source clause, including
  a default-argument wrapper) and `:identity` (as many stored as source
  clauses).
- **Measured** with an instrumented replay of `Module.Types.infer/7` as the
  oracle on `c24c235`: the structural classes cover 20,051 of 21,439
  functions with an inferred signature (93.5%) and 22,826 of 27,742 stored
  clauses (82.3%) on the fifteen corpora; the replay reproduced 98.9% of the
  signatures and agrees on all 19,825 structural functions it could check.
  All nine corpus clause conflicts (seven Absinthe, `Ash.Page.page_opts/1`,
  `Oban.Registry.via/3`) are identities.
- **Not adopted:** every typed mapping (head types recomputed with
  `Pattern.of_head/8`). Fresh heads differ from the compiler's (E1: the
  checker's `subpatterns` leak between definitions, 119 of 3,237 functions
  on the corpora; E2: protocol implementations; E3: gradual bounds widened
  by subtraction), and the review found wrong exact claims on warning-free
  fixtures (R1, fixed in the experiment; R2, `strict_a1`, not fixable
  there). Corpus agreement is not proof.
- **Product** (`SpecLint.ClauseMapping`, `SpecLint.Analysis`,
  `SpecLint.Rules.ReturnConflict`, `--explain`): a clause conflict names
  `source clause: #k, line L` or "not determined", and carries
  `data.source_clause` and `data.clause_mapping`. The issue line,
  prerequisites, gates and fingerprints are unchanged, and
  `clause_reachable` blocking stays function-wide for every function:
  diagnostic lines are not attributed to clauses, and no corpus conflict is
  blocked by a diagnostic, so per-clause blocking would change no gate.
  Tests: `test/spec_lint/clause_mapping_test.exs` (13, under both lines,
  with the raising and generated-redundant shapes pinned per adapter).
- **Experiment hygiene** (review findings): `bench/clause_mapping/` passes
  formatting and strict Credo, exits 2 on any compiler but `c24c235`,
  decides the structural classes before any typed solve, marks the typed
  variants' exact claims `unverified`, holds the counterexamples as
  fixtures, and commits its summaries (`results/`).

## Milestone 3 review: sixteen findings

| Finding | Severity | Outcome |
| --- | --- | --- |
| Forced recompile is a no-op when `compile` already ran in the VM; the other build's BEAMs recorded as verified | high | fixed: the Mix tasks re-enable `compile`, `compile.all` and every compiler before a forced compile, and a forced compile that still returns `:noop` exits 2 without a record; tests for `mix do compile + spec_lint`, a task defined in the project, and the other compiler (cross test step e) |
| A dependency of the other compiler line silently changes the verdict | low | fixed: the Mix tasks read the chunk version tag of every dependency BEAM (`BuildRecord.foreign_dependencies/2`, `Beam.checker_version/1`) and exit 2, removing the owned records so the project recompiles once the dependency is rebuilt; integration test; DESIGN 5.2 narrows the fail-closed claim (same-line builds and `SpecLint.Run` without the Mix task are documented limits) |
| 1.20.4 map DNF line repeating the open-map top literal read as an intersection | medium | fixed in `DescrWalk` (the top literal is dropped when another positive remains, for labels and printing); test under both lines; the Milestone 1 reference printer follows the same rule |
| 1.20.4 prints the non-binary bitstring key domain as `bitstring()` | low | documented in audit row 27 and pinned per adapter in `printing_test.exs`; not rewritten, since the printer shows the running compiler's `Descr` output and the views are equal |
| `robust_a1` exact and wrong on a redundant clause | high | fixed in the experiment (errored clauses get an unbounded `hi`); `Adv3.redundant/1`, `Adv4.gen_red/1` are fixtures |
| `strict_a1` exact and wrong (leak plus generated repeated guard) | medium | documented: typed exact claims marked `unverified`; `Adv6.b/1` is a fixture (still wrong for `strict_a1`) |
| Structural identity depends on the typed solve | low | fixed: structural classes first, non-trivial from clause counts; `Adv7.ident/1` fixture |
| Cited REPORT.md missing | low | fixed: the report is `bench/clause_mapping/README.md` (sections Pipeline, Invariants, E1-E3, R1-R3, Fixture results), and the citations point there |
| `bench/clause_mapping` fails format and strict Credo | medium | fixed, with no change to `.credo.exs` |
| `bench/clause_mapping` undocumented | medium | fixed: README with purpose, invariants, results, how to run and limits; M4 status in NEXT_STEPS.md |
| `clause_mapping` runs on any compiler | low | fixed: exits 2 unless preflight selects `V121` at `1.21.0-dev+c24c235` |
| README: unsupported compilers | low | fixed: 1.19 and 1.20.0-1.20.3 are refused by Mix (exit 1); the exit-2 report applies inside the version range |
| README: fingerprint divergence overstated | low | fixed: 28 of 65 shared (5 of 30 outside the standard library, none of Absinthe's 9) |
| DESIGN 5.2: "pins one 1.21 revision" | low | fixed: one adapter per compiler line |
| Cross-compiler test passes as a no-op | low | fixed: excluded by `test_helper.exs` without `SPEC_LINT_OTHER_ELIXIR`, fails with `--only cross_compiler` and no variable; documented in README "Development" |
| `ConsumerTest` depends on test order | low | fixed: a fresh fixture per test; seeds 845457, 368644, 1 and 2 pass |
| M3 commit trailers | low | no change: the trailer follows the attribution the session's harness specifies |

Gates on the final tree (Milestones 3 review and 4 together):

| | `c24c235` | `648b2a9` | 1.20.4 |
| --- | --- | --- | --- |
| Test suite | 431 passed, 10 excluded | 431 passed, 10 excluded | 434 passed, 7 excluded |
| Cross-compiler test (`--only cross_compiler`) | passes, 1.20.4 as the other | passes, 1.20.4 as the other | passes, `c24c235` as the other |
| Formatting, strict Credo (including `bench/clause_mapping/`) | clean | clean | clean |
| Dialyzer (own PLT per compiler) | 0 errors | 0 errors | 0 errors |
| Self-check (`mix spec_lint --ci`) | 407 slices, exit 0 | 407 slices, exit 0 | 407 slices, exit 0 |

The excluded tests are the other line's adapter-pinned tests (the cross
test runs separately with `SPEC_LINT_OTHER_ELIXIR`). The consumer
integration tests pass with seeds 845457, 368644, 1 and 2.

## Milestone 3 delivered: the Elixir 1.20 adapter (2026-09-29)

`SpecLint.Compiler.V120` qualifies Elixir 1.20.4 (revision `759443e`,
the precompiled release, checker chunk `elixir_checker_v8`, adapter id
`1.20.4+759443e`) next to `V121` (`c24c235`, `648b2a9`). 1.19 is not
supported. Commits `516e7e4` (adapter, selection, tests), `bfbe66f` and
`f364fa1` (toolchain), `f0069b0` (audit), `839a415` (replay) and the
documentation after them. Formatting and Credo were checked on the
committed tree; the source-clause mapping experiment
(`bench/clause_mapping/`), untracked then, passes both since Milestone 4.

| | 1.21 (`c24c235`, same tool) | 1.20.4 |
| --- | --- | --- |
| Test suite | 415 passed, 8 excluded (pinned to V120); the same under `648b2a9` | 418 passed, 5 excluded (pinned to V121) |
| Dialyzer, strict Credo, formatting | 0 errors, clean (c24c235 and 648b2a9, separate PLTs) | 0 errors (own PLT), clean |
| Self-check (`mix spec_lint --ci`) | 401 slices, exit 0 (also 648b2a9) | 401 slices, exit 0 |
| Cross-compiler test (`SPEC_LINT_OTHER_ELIXIR`) | passes with 1.20.4 as the other compiler (under c24c235 and 648b2a9) | passes with c24c235 as the other compiler |
| Capability probes | 11 of 11 | 11 of 11 (also on OTP 29.0.1) |
| Corpora compiled | 14 of 14 | 14 of 14 (none fails to compile) |
| Compared slices, fifteen corpora | 4,204 | 4,170 (the standard library differs: 1,743 against 1,777) |
| Findings / gates | 63 / 9 | 65 / 9 |
| Unknown obligations | 3,113 | 3,095 |
| Absinthe `run.sh` wall time | 72 s | 66 s |

- **Audit** (`bench/corpus/toolchain/audit-1.20.4.md`, 35 rows: the 25 of
  the 648b2a9 audit and ten for the encodings the adapters read and the
  checker behaviours the tests pin). Every row was probed on 1.20.4
  (`audit_probe.exs`, the adapter's probes). Rows that differ: the `Descr`
  exports (`union/2` for `opt_union/2`, no public `unfold/1`, no
  `recursive/1`), the map field encoding (the `not_set()` marker in the
  value) and key domains (`:bitstring` for `:bitstring_no_binary`, marked
  values), recursive nodes (absent), the `apply_infer/2` union function,
  the chunk version, `Code.Typespec` (leaves `-nominal` types out), the
  build digests, a raising source clause (stored as `-> none()` by 1.20.4,
  dropped by 1.21) and compound impossible guards (reported by the 1.20.4
  checker, not by 1.21). Row 19 (`for ... into:`) behaves as on `c24c235`:
  no narrowing.
- **Adapter.** All descriptor construction, inspection, application,
  canonical serialisation and printing differences are in the adapters.
  The code both share moved out of `V121` without a change in behaviour
  (`SpecLint.Compiler.Qualification`, `SpecLint.Compiler.DescrWalk`): the
  fifteen-corpus replay under `c24c235` with the new tool equals
  `reports/m1_review/` in every ledger, finding, gate, fingerprint, exit
  code and BEAM MD5 (only the `exck` and `artifacts` fields added by the
  Milestone 2 review differ; `reports/elixir-1.20.4/c24c235/summary.json`).
  1.20 lacks recursive descrs and `unfold/1`: V120 reports
  `recursive_types: false` and expands `term()` itself (checked equal to
  `term()` at preflight). The translator builds no recursive descr on
  either line (recursive typespecs are cut off with `recursive_cutoff`),
  so no loss is specific to 1.20; its recursive-type tests pass unchanged
  under both adapters. The one translation difference is row 18: an Erlang
  `-nominal` type read from its BEAM translates as `unresolved_remote_type`
  on 1.20.4 and `nominal_boundary` on 1.21, with the same bounds (a test
  pins it per adapter).
- **Selection and artifacts.** The adapter is chosen from
  `System.version()` and the running checker chunk version
  (`select_adapter/2`); revision and build identity are checked by its
  preflight. The build record now names the Elixir version, checker chunk
  version and adapter module. A 1.21 artifact under 1.20.4, and the
  reverse, is recompiled by the Mix tasks, and refused (exit 2) when read
  without them: with a record, "compiled by another compiler line
  (1.21.0-dev+c24c235, checker elixir_checker_v10, adapter
  SpecLint.Compiler.V121), whose artifacts the running adapter cannot
  read"; without one, `unsupported checker chunk ... version
  :elixir_checker_v10, the running checker writes :elixir_checker_v8`. The
  integration test covers both directions (`SPEC_LINT_OTHER_ELIXIR`: 1.20.4
  under c24c235, c24c235 under 1.20.4) and c24c235/648b2a9.
- **Pinned per adapter** (tests tagged `adapter:`, or exact expectations
  per adapter): the classes of the nine omission fixtures and the two
  clause-local stand-ins (identical on both lines: seven `unknown`, two
  `possible_domain_escape`; `page_opts/1` and `via/3` `clause_conflict`,
  gated with the clause-local qualification), the stored clause of a
  raising clause, the compound impossible guards, nominal typespecs, the
  row 19 verdict, the report envelope, and the `Descr` probe stubs.
- **Corpora** (`bench/corpus/reports/elixir-1.20.4/`, README there). All
  fourteen OSS corpora compile under 1.20.4 into separate build paths. On
  all of them coverage, obligations, unknown reasons, loss kinds, findings,
  evidence classes, gates (subject, rule, slice and stored clause) and exit
  codes equal the 1.21 replay: no gate differs, so none needed triage. The
  standard library is another library (1.20.4's): 1,743 slices, 35
  informational SL002 findings against 33, no gate on either; the three
  findings only 1.20.4 has come from its more precise returns
  (`DateTime.diff/3`, `NaiveDateTime.diff/3`: `dynamic(float() or
  integer())` where 1.21 has `dynamic()`) and its stored raising clause
  (`Float.round/2`: `(float(), term()) -> none()`). Only 28 of 65 finding
  fingerprints are shared (0 of Absinthe's 9, including its seven gates),
  because the canonical form of the stored and spec types differs between
  lines. Baselines are therefore per adapter
  (`reports/elixir-1.20.4/baselines/`); another line's baseline is not
  applied and CI exits 2.

## Milestones 1 and 2 delivered (2026-09-29)

Both milestones of the six-milestone plan (`NEXT_STEPS.md`, "Milestones")
are delivered and reviewed; M3 (the 1.20 adapter) followed, above.

| | Before | After |
| --- | --- | --- |
| Absinthe `Run.execute/3`, no rules | 576-684 s (606 s re-measured) | 60.6-66.8 s, median 62.9 s (five runs) |
| Absinthe `Run.execute/3`, default rules | | 62.5-64.4 s |
| Absinthe product run (`run_on_ebin.exs --ci --format json`) | 345 s (Phase 3) | 73-75 s |
| Absinthe JSON rendering | 1-78 s (Milestone 1) | 0.13-0.17 s |
| Types printed by `Run.execute/3` | most of the run | 0 |

- **M1 exit criteria.** Coverage, classifications and gate decisions are
  preserved on all fifteen corpora (4,204 compared slices, 63 findings, 9
  gates, every exit code). Fingerprints were unchanged by Milestone 1; the
  review's correctness fixes (union member order, shadowed required map
  keys) changed 13 of 63, including all seven gated Absinthe findings, with
  the baseline migration documented. **The 60-second Absinthe target is not
  met** (60.6-66.8 s); the remaining cost is translation and garbage
  collection of about 3.3 GB of retained bounds.
- **M2 exit criteria.** A clean machine builds 648b2a9 from GitHub and
  qualifies it without the fork. Differences from `c24c235`: the fifteen
  corpus reports are identical except the adapter id and 40 BEAM md5
  values (build paths, the build date, the two changed compiler modules,
  nondeterministic compilation); 3 of 3,926 stdlib stored signatures
  differ with no report change; and the `for ... into:` narrowing of
  648b2a9 gates a correct spec (audit row 19, `UPSTREAM_BUGS.txt` item 11),
  in none of the corpora.

### Milestone 2 review: twelve findings, all resolved

- **High: artifacts of the other build.** Both qualified builds are
  `1.21.0-dev` with chunk v10, so Mix kept the other build's BEAM files and
  `mix spec_lint --ci` reported that build's verdict under the running
  adapter id (a gate passed or failed wrongly). The Mix tasks now write a
  `SpecLint.BuildRecord` per owned application (adapter id, build digest,
  SHA-256 of every BEAM) and recompile with `--force` unless it names the
  running build and the BEAM files match; `SpecLint.Run` refuses a
  mismatched record (exit 2). Reports add a per-BEAM `exck` digest (the
  `beam_lib` MD5 leaves the checker chunk out) and an `artifacts` object.
  An integration test compiles with one build and lints with the other, in
  both directions (`SPEC_LINT_OTHER_ELIXIR`), and gets the native verdict
  each time. Dependencies are not recorded (DESIGN.md 5.2).
- **High: a modified build of a qualified SHA.** Preflight now pins the
  code of 14 compiler modules per revision (`:compiler_identity`,
  `SpecLint.Compiler.BuildIdentity`): the reviewer's `c24c235` build with
  the row 19 fix reverted, and the body experiment build, now fail
  preflight (`Module.Types.Expr`, `Module.Types`). The digests are the same
  for builds in other directories and with OTP 28.0, 28.3.1 and 28.5.0.1.
- **Medium: corrupt BEAM under a deep path.** `beam_lib` makes an atom of
  a file name when it reports an error, so a path over 255 characters
  crashed the run (exit 1, the gating code) instead of exit 2. BEAM files
  are decoded from their contents (`SpecLint.Beam.chunks/3`); a test uses
  a path over 255 characters.
- **Medium: debug info unaudited.** New `:debug_info` probe and audit row
  23 (definition tuples, `:line`, `:generated`, `from_super: false`); the
  adapter's moduledoc no longer claims to be the only caller of
  `:elixir_erl`.
- **Low, all done:** `failed/1` in the probe tests now also checks that a
  CI run exits 2, for every probe test (the earlier claim was true for 2 of
  27), and stubs were added for untested sub-checks; the `:pattern_checker`
  probe covers the `:unused_clause` diagnostic; row 8 is corrected
  (`unfold/1` expands `term()`) and recursive nodes are probed; row 1's
  count is corrected (42 pairs and 37 names then, 43 and 38 with
  `recursive/1`); row 18 and the `:typespec_kinds` probe cover
  `fetch_specs/1` and `spec_to_quoted/2`; the replay README says the
  reports were produced from the uncommitted tree whose `source_sha256`
  matches `41f56c3` (checked on a clean clone) and how to verify a
  regeneration with `compare_replay.sh`; `provenance.sh` records the
  path-independent `identity.exs` digests and no longer claims its hashes
  are path independent; the corpus README lists repository URLs and a
  checkout snippet (the manifests are unchanged: their hashes are in the
  committed provenance).

Preflight now runs eleven probes; the audit has 25 rows. Validation under
both `c24c235` and `648b2a9`: 401 tests (including the cross-compiler
test), strict Credo (70 checks), formatting, Dialyzer (0 errors) and the
self-check (`mix spec_lint --ci`: 303 slices, exit 0). The extra work per
run (the build record check and the `ExCk` digest per BEAM, before the
analysis) costs no measurable time on Absinthe: one
`bench/absinthe_profile.exs` run with the default rules after the review
changes took 61.6 s for `Run.execute/3` (9 findings, exit 1, complete),
below the earlier 62.5-64.4 s.

## Milestone 2: upstream Elixir 648b2a9 qualified

The compiler adapter is qualified for unmodified upstream Elixir
`648b2a94934664cfd2c788348d02d799c68faa69` (adapter id
`1.21.0-dev+648b2a9`) next to the fork revision `c24c235`. Toolchain,
audit and replay are in `bench/corpus/toolchain/` and
`bench/corpus/reports/upstream-648b2a9/`.

- **Build reproducibility.** `bench/corpus/toolchain/build_elixir.sh REV
  DEST` fetches one upstream revision, builds it with `make compile` and
  `SOURCE_DATE_EPOCH` set to the commit time, and prints a path-independent
  identity (`identity.exs`: code and `ExCk` digests over 447 modules). A
  fresh clone from GitHub, built under `env -i` with only OTP 28.5.0.1 on
  `PATH`, has the same identity as a worktree build of the same commit.
- **Audit** (`audit-648b2a9.md`, 22 rows, each with a probe or test on both
  builds; 25 after the review above). The two revisions share `25fa6682c`; the internals SpecLint reads
  are unchanged (same source blobs, same BEAM md5 for `Descr`, `Module.Types`,
  `Pattern`, `ParallelChecker`, `:elixir_erl`, `Code.Typespec`,
  `Mix.Compilers.Elixir`; the `apply_infer/2` source and `@max_clauses 16`
  identical). Rows that differ: the revision itself; a new precise
  `:erlang.--/2` rule (3 stdlib stored signatures change, no report
  changes); and **the `for ... into:` narrowing**: upstream lacks the fork's
  fix and stores `(term(), bitstring())` for a function that accepts an
  atom, so SpecLint gates a correct spec (SL003, exit 1). This is a
  reproduced upstream soundness violation (`UPSTREAM_BUGS.txt` item 11),
  pinned per revision by a test and listed in the README support matrix;
  it does not occur in the fifteen corpora.
- **Capability probes.** `SpecLint.Compiler.V121.preflight/0` now runs nine
  probes after the revision check (`capability_probes/0`): `Descr` exports,
  the term layout the adapter reads (bitmap bits, atom sets, tuple, map and
  list literals, `fun()`, `dynamic`, `term`, `none`), `Descr` semantics,
  the checker version, the `ExCk` layout of a sample chunk, the
  `apply_infer/2` copy against `remote_apply/7` on both sides of the cutoff,
  the pattern checker on a dead and a live clause, the `Code.Typespec`
  kinds, and the compile manifest reader. `preflight/1` takes the internals
  to probe; 27 tests substitute a missing or changed internal (a dropped
  function, a flipped map field flag, an open tuple, a moved bitmap bit,
  covariant functions, a new chunk version, a renamed chunk key, a raised
  cutoff, another diagnostic tag, a lost typespec kind, a changed manifest
  sentinel, a raising probe) and check that preflight fails naming the
  probe, and that a CI run is then incomplete with exit 2. *Corrected by
  the review: only two of them checked the exit code; all probe tests do
  now, and preflight runs eleven probes (above).*
- **Tests under upstream.** The whole suite (368 tests, including the
  consumer, umbrella and build integration projects run through the Mix
  task) passes under both compilers, with the upstream build of the
  project in a separate `MIX_BUILD_PATH`; strict Credo, formatting,
  Dialyzer (0 errors; upstream PLT in a separate `SPEC_LINT_PLT_DIR`) and
  the self-check (`mix spec_lint --ci`: 288 slices, exit 0) pass under
  both. Two test harness fixes were needed: the consumer fixtures clear an
  inherited `MIX_BUILD_PATH`, and the report path test accepts a build
  outside the project root. Before them, the only failure under upstream
  was that path assertion.
- **Replay.** The fifteen corpora, recompiled with the upstream compiler
  into separate build paths (`compile_corpora.sh`; checkouts verified
  clean before and after), give reports identical to `../m1_review/` except
  the adapter id and the BEAM identities: same exit codes, 4,204 compared
  slices, 63 findings, 9 gates, every fingerprint. The 40 differing BEAM
  md5 values are build paths, the build date, the two changed compiler
  modules, and nondeterministic compilation in Phoenix LiveView, Ash and
  Nx (they also differ between two `c24c235` builds). Baselines: switching
  compilers changes the adapter id, so a baseline must be regenerated
  (`mix spec_lint.baseline`); its entries are unchanged.

## Milestone 1 review: rendering, union order, shadowed map keys

Four review findings on `e4fc0c7`, all resolved
(`bench/corpus/reports/m1_review/`):

- **JSON rendering time (1-78 s) is explained and removed.** Printing a map
  type loads the module of every struct it prints
  (`Module.Types.Descr.maybe_struct/1`), and each code load in the run
  process, which holds about 3.3 GB of analysis results on Absinthe, took
  seconds; the reporters' own modules, and the coverage, reachability,
  rule and policy modules first used after the analysis, were loaded
  there too. `SpecLint.Report.render/2` now renders in a short-lived
  process that receives the run without its analysis results, and
  `Run.execute/3` loads SpecLint's modules and the standard library
  modules its later stages use before the analysis. Absinthe's JSON report
  renders in 0.13-0.17 s, and the product run takes 73-75 s end to end,
  against 109 s.
- **The 60-second target is not met.** `Run.execute/3` on Absinthe takes
  60.6-66.8 s without rules (median 62.9 s of five runs) and 62.5-64.4 s
  with the default rules. The earlier "met without rules" rested on one
  59.3 s sample.
- **Union member order no longer changes fingerprints.** The compiler
  fuses two tuple or map literals that differ in one position when it
  unites them, so `{:ok, binary()} | {:error, :timeout} | {:error, atom()}`
  and its reverse were different terms with different fingerprints. The
  translation now unites a union's members in Erlang term order.
- **A shadowed required map key is no longer called exact.** In
  `%{optional(any()) => any(), year: integer()}` (the `Calendar.date()`
  form: keyword keys come last), Dialyzer's reading drops the requirement,
  and it was translated as exact, so the lower bound admitted maps without
  `:year`. The upper bound now covers Dialyzer's reading and the required
  one, the lower bound requires the key, and `map_key_widened` is
  recorded. The order of overlapping associations stays significant (the
  first wins), so reordering them changes the fingerprint; a test pins it.

The fifteen-corpus replay keeps every exit code, all 4,204 compared slices,
63 findings and 9 gates; eleven reports are byte-identical to Milestone 1.
**13 fingerprints changed**, including all seven gated Absinthe findings,
so baselines that acknowledge them must be regenerated
(`mix spec_lint.baseline`); the baseline format version is unchanged.
Validation: 337 tests, strict Credo, formatting and Dialyzer pass.

## Milestone 1: no type printing during classification

The Absinthe profile (`bench/corpus/reports/phase4/absinthe.profile.md`)
showed that more than 90 percent of the product run was spent printing
types inside the evidence classifier. Classification now works on `Descr`
terms only: `SpecLint.Evidence` components keep their `descr`, rule details
stay unrendered until a reporter or `--explain` shows the finding, and
`SpecLint.Run.execute/3` prints no type. The adapter printer returns the
same strings as before but memoises literals and stops printing the
complement form once it cannot be shorter. BEAM hashes are read before the
analysis, and each reachability check runs in its own process, because the
run process's heap (about 3.3 GB of translated bounds on Absinthe) made
garbage collection dominate both.

Fingerprint audit: `SpecLint.Compiler.canonical/1` was already structural
and does not print. It is unchanged, so fingerprints, baselines and the
baseline format version are unchanged; no migration is needed.

Absinthe, `bench/absinthe_profile.exs`: `Run.execute/3` without rules (what
the Phase 4 profile measured) went from 576-684 s (606 s re-measured on the
same machine) to 59.3 s; with the default rules it takes 65-68 s, so the
60-second target is met only without rules. The complete product run
(`run_on_ebin.exs --ci --format json`) takes 109 s, against 345 s in Phase 3.
The remaining cost is translation (about 31 s) and garbage collection of the
retained results; JSON rendering in the run process varied from 1 s to 78 s
between runs and was not investigated further. *Superseded by the review
above: the 59.3 s was one sample of a 60-67 s spread, so the target is not
met, and the rendering variance was module loading in the run process
(now 0.13-0.17 s; end to end 73-75 s). Fingerprints did change after the
review.*

The fifteen-corpus replay (`bench/corpus/reports/m1/`) is complete for the
first time since Phase 3. Its fourteen reports with a Phase 4 counterpart
are byte-identical to it. Absinthe matches the Phase 3 flag-on report
except for the earlier `stored signature clause` label, and its seven
`parse/1` findings match the scoped Phase 4 run exactly: 4,204 compared
slices, 63 findings, 9 gates before and after, every fingerprint unchanged.
New tests: a stub adapter that cannot print gives identical classifications
and runs, `Run.execute/3` prints zero types and rendering the fixture
findings stays within a budget, the printer matches the previous
implementation on 835 types, and Evidence and Compare import no printer.
Validation: 329 tests, strict Credo, formatting, Dialyzer and the self CI
check (282 slices, exit 0) pass.

## Phase 4: guard qualification and required-check failures

The two defects in `PHASE_3_REVIEW.md` are fixed. Absence of compiler
warnings is no longer the only protection against impossible compound guards.
SL001 clause conflicts additionally require concrete, statically evaluated
head-and-guard witnesses for all guarded source clauses of the function.
Each witness must be rejected by all preceding clauses. The interpreter
only evaluates supported patterns and whitelisted pure Erlang guard BIFs;
it never invokes target functions. Unsupported syntax or exhausting the
bounded search blocks qualification as `guard_feasibility: "unproven"`.
This remains function-wide and does not prove a stored clause's normal return
or map it to a source clause. Unguarded clauses still rely on the existing
compiler diagnostics and stored-domain shadowing checks.

An operational failure in a reachability check needed for an otherwise
eligible gate now makes the run incomplete and exits 2 in CI, under both
qualification settings. Baselines cannot acknowledge away that failure.
Disabled SL001 and findings already blocked by other prerequisites do not
make such checks required. Conservative unknown guard feasibility is distinct
from an operational failure.

The helper experiment in `bench/helper_experiment/REPORT.md` recovers exact
inline signatures in four synthetic cases using a narrow source transform.
It is not a compiler patch or a production backend. Raising, branching and
recursive helpers remain unsupported, and the motivating `sign(:nan)` miss
remains dynamic. **New real-library detections: zero.** The next precision
experiment should address normal-return summaries of a helper that either
returns its input or raises, with evaluation and exception controls. Keep
SL002 informational and judge adoption by independently witnessed real-code
improvement, not synthetic success alone.

Independent Sol review and root adversarial probes corrected guard-alternative
semantics (multiple `when` guards are OR), bounded candidate construction,
prior-clause exclusion, and prototype handling of guarded overloads,
call-shaped ASTs, quotes and captures. Regression tests retain these controls.
Validation: 322 tests, strict Credo, formatting, Dialyzer and the self CI
check pass. Fourteen complete corpus replays preserve their ledgers and two
known gates. A scoped Absinthe run preserves seven more. **The full Absinthe
replay was stopped after approximately 15 minutes and remains incomplete**;
do not describe this as a completed 15-project replay. See `PHASE_4_PLAN.md`
and `bench/corpus/reports/phase4/summary.json` for the detailed result.

## Phase 3 history

## Close phase (2026-09-29): clause-local qualification adopted

**Decision.** `clause_local_qualification` now defaults to `true`, and the
clause conflicts it qualifies gate in both profiles. An SL001 clause
conflict is qualified by its own clause: its whole domain must be inside
the spec's argument lower bounds (`clause_contained_in_lo`), and an arrow
elsewhere in the slice no longer blocks it. `--no-clause-local-qualification`
or `clause_local_qualification: false` restores the slice-wide arrow
prerequisites. Rationale and the decision rule are in
`bench/corpus/clause_local_qualification.md`, "Decision".

| Corpora | Compared slices | SL001 findings | SL001 gates, flag off → on | New gates triaged |
| --- | ---: | ---: | --- | --- |
| stdlib, 6 original libraries, 6 expansion projects (tuned) | 3,364 | 2 | 1 → 2 | `Ash.Page.page_opts/1`: true positive, witnessed |
| absinthe, tesla (fresh holdouts, frozen before the experiment) | 840 | 7 | 7 → 7 | none |

False positives among new gates: 0 of 1. Negative controls: all pass,
including the review's dead-clause controls. The holdouts had no clause
conflict blocked by an arrow prerequisite, so they could not confirm a
benefit; the decision rests on the soundness argument and the controls.
Confirmation runs with the final tree and the default configuration
(`reports/expansion/clause_local/default/`): stdlib 0 gates (exit 0),
absinthe 7 (exit 1), tesla 0 (exit 0), matching the flag-on measurement
finding for finding.

**Independent adversarial review.** Twelve findings, all resolved
(`clause_local_qualification.md`, "Independent review"):

- **`clause_reachable` missed dead clauses** whose guard contradicts their
  pattern (a false positive with the flag, and in the existing policy on
  arrow-free slices). It is now also decided by the compiler's own pattern
  and guard check, re-run over debug info (`SpecLint.Reachability`), for
  both settings.
- **Clause findings name the stored signature clause**, which the details
  now say ("stored signature clause #k").
- **`clause_contained_in_lo` is now tested**, including an empty clause
  domain.
- **Three Ash integration witnesses** used inputs outside the declared
  struct types. `page/2` and `Policy.solve/1` keep their verdicts with
  repaired inputs; `Query.apply_to/3` is downgraded to probable
  (`holdout_triage.md`).
- **`Ash.Page.page_opts/1`'s catch-all also escapes** (it returns a keyword
  list, never a page). SpecLint does not report it.
- **Provenance paths** now use placeholders, and the docs are corrected.

**Remaining open items at Phase 3 (guard qualification and failure handling
are superseded by Phase 4 above).**

- `clause_reachable` is `unchecked`, not proven, when the type checker
  reports nothing: a dead clause it cannot see (a contradictory numeric
  guard, a clause only the Erlang compiler reports) could still gate. A
  per-source-clause reachability verdict in the checker chunk would close
  it (DESIGN section 12).
- The re-check blocks per function, not per clause, and findings cannot
  name their source clause or line, because the chunk does not store the
  source-to-stored clause mapping.
- `Ash.Query.apply_to/3` has no in-domain witness; `page_opts/1`'s
  catch-all is a silent false negative.
- Recall is unchanged in substance (gated recall on the nine known
  omissions is 0 of 9). The two compiler limits behind most misses now have
  minimal counterexamples in `bench/corpus/compiler_counterexamples/`.

## Follow-up delivery: broader evidence and build integrity

The six-project expansion adds 1,252 eligible functions and 1,260 spec
slices. All runs complete without unsupported/unavailable slices; 1,037
obligations remain unknown. There are 14 findings and one CI gate, a
confirmed return-shape omission in `Oban.Registry.via/3`. The actual Req
path-dependency consumer also passes. Full tables and source judgments are
in EXPERIMENTS.md and `bench/corpus/{expansion_triage,holdout_triage}.md`.
Do not treat a clean run as evidence that the project has accurate specs.

Build integrity now rejects unreadable owned-app inventories, corrupt BEAMs,
and BEAM filename/module mismatches with exit 2. A corrupt manifest falls
back to a valid `.app`; a valid empty manifest remains authoritative over a
stale `.app`. Regression tests cover all of these cases.

Benchmark changes enforce revision pins, retain complete compressed reports,
validate reduced report schemas, record compiler/tool/artifact hashes, and
fail on incomplete product runs. Body rebuilds use fresh output directories;
metrics distinguish gates, candidates, reports and unavailable analysis. All
nine stand-in omission fixtures now have direct runtime assertions. The
patched body-fixture rerun does not change the decision against a production
body backend. See NEXT_STEPS.md for the completed plan and validation.

## What exists

`mix spec_lint` checks `@spec` declarations against the signatures the
Elixir compiler infers. It reads compiled BEAM files. It runs no Dialyzer,
needs no PLT, never starts the application, and never calls project
functions.

It has about 8,800 lines in `lib` and 5,800 in `test`:

| Component | Module | State |
| --- | --- | --- |
| Compiler adapter | `SpecLint.Compiler`, `SpecLint.Compiler.V121` | Qualified for Elixir 1.21.0-dev `c24c235` (fork) and `648b2a9` (upstream), checker chunk `elixir_checker_v10`. Preflight with nine capability probes, chunk decoder, every `Descr` call, a copy of `apply_infer/2` with its 16-clause cutoff, a canonical `Descr` serialisation and a printer. |
| BEAM reader | `SpecLint.Beam`, `SpecLint.Project` | Reads `ExCk`, `Dbgi` specs, types and debug info (including `use`-injected overridable defaults). Handles owned ebins, umbrella children and exclude globs, and checks every module the build lists has its BEAM file (compile manifest, or `<app>.app`). |
| Translator | `SpecLint.Translate`, `SpecLint.Bound`, `SpecLint.TypeCache` | Turns spec AST into `{lo, hi}` bounds with loss records (the section 6 kinds plus `map_key_widened`) and integer intervals. `expand_opaque` is optional. |
| Comparison | `SpecLint.Compare` | Raw per-slice relations: application, extra and missing, containment per clause (against `D_hi` and `D_lo`), overlap (certain or unknown), top-only, near-top, clause shadowing, and the dynamic probe. |
| Reachability | `SpecLint.Reachability` | For functions with a clause conflict only: re-runs the compiler's type checker over debug info and keeps its pattern and guard diagnostics, which block `clause_reachable`. |
| Evidence | `SpecLint.Evidence` | The DESIGN 3.1 classifier, steps 1 to 9: union level plus per-clause evidence, the F1 subtraction check with widening, near-top handling, and gradual payloads. |
| Rules | `SpecLint.Rules.*` | SL001 (slice and clause conflict), SL002 (informational), SL003, SL004 and SL005 (hints, off by default), SL006, SL007 (a stub, since no backend exists), SL008. |
| Policy | `SpecLint.Policy` | Gating by evidence for the `review` and `soundness` profiles, `--warnings-as-errors` (which never touches SL008), and the coverage policy. |
| Coverage | `SpecLint.Coverage` | Per-slice inventory and a ledger with denominators. Unknown obligations are counted by reason, and regressions are checked against the baseline inventory, including specs removed from functions that are still exported and overloads removed from multi-clause specs (`unanalysed`), but not user overrides deleted in favour of a `use`-injected default. |
| Baseline | `SpecLint.Baseline` | Structural fingerprints, acknowledgements with reason, owner and expiry, the gate state each finding was written with (`blocked`, `gate_changed`), inventory acknowledgements, stale detection (only for analysis that happened, plus compared entries whose slice vanished), regeneration that keeps what was not analysed, and adapter reconciliation per file and per entry (`pending_reconciliation`). |
| Run | `SpecLint.Run` | One run with exit code 0, 1 or 2. Completion is complete, partial or incomplete. Coverage is checked whatever rules are selected. |
| Reports | `SpecLint.Report.Console`, `SpecLint.Report.Json`, `SpecLint.Explain` | Console output, a versioned deterministic JSON envelope written atomically, and `--explain`. |
| Mix tasks | `mix spec_lint`, `mix spec_lint.baseline` | Options are parsed before compile. Compile failure exits 2. With `--format json` to stdout, compiler output goes to stderr. |
| Bench | `bench/experiment.exs`, `bench/run_on_ebin.exs`, `bench/body_experiment.exs`, `bench/triage/` | The SL002 experiment runner, the product pipeline run over explicit ebins (OSS corpora), the body-backend experiment (runs only under a compiler carrying the `warnings/7` hook, `bench/corpus/warnings7.patch`; `bench/corpus/body_run.sh`), and the Phase 0 triage probes (`per_clause.exs`, `near_top.ex`). `run.sh` and `body_run.sh` run under bash 3.2 or later. |

The tests cover the following. Some are unit tests, some are fixture
corpora (`test/support`), and one is a consumer integration project built
in a separate OS process:

- translation;
- the application-rule copy;
- relations;
- evidence classes on 25 experiment fixtures;
- rules and policy;
- fingerprint stability: line changes, function reordering, spec clause
  reordering, recompilation, a fresh VM, alias and variable renames, and
  union reordering;
- baseline decisions;
- exit codes, including canaries for an internal failure and a checker
  chunk version mismatch;
- JSON determinism.

## How to run

Toolchain: Elixir 1.21.0-dev (`c24c235`) from `~/elixir` on `PATH`,
Erlang/OTP 28. Upstream `648b2a9` is qualified too; build and select it as
`bench/corpus/toolchain/upstream-1.21-648b2a9.md` says.

```
mix spec_lint                                 report, exit 0
mix spec_lint --ci                            gate new findings (review profile)
mix spec_lint --ci --profile soundness
mix spec_lint --explain MyApp.Store.lookup/1
mix spec_lint --format json --output spec-lint.json
mix spec_lint --format json > spec-lint.json  stdout carries only the JSON
mix spec_lint.baseline                        write .spec_lint_baseline.json
```

To run on a project SpecLint cannot be added to, such as the OSS corpora:

```
MIX_ENV=test mix run bench/run_on_ebin.exs -- --ebin DIR [--code-path DIR ...] \
  --root DIR [--ci] [--format json --output FILE] [--write-baseline FILE]
MIX_ENV=test mix run bench/experiment.exs -- --ebin DIR ... --label NAME --out FILE.json
```

Quality gates, all green on the Close-phase tree (2026-09-29):

```
mix format --check-formatted
mix credo --strict            # no issues (70 checks)
mix test                      # 311 tests, 0 failures (includes test/integration)
mix dialyzer                  # 0 errors (PLT in priv/plts)
mix spec_lint --ci            # self-check: 276 slices compared, exit 0
```

## Measured numbers

All measurements were made on the pinned toolchain. Details are in
`EXPERIMENTS.md`.

**Coverage.** The corpora were the stdlib (elixir, eex, ex_unit, iex,
logger, mix) and six OSS libraries: jason, decimal, nimble_options, mime,
plug and ecto. On real code that is 2,038 spec'd functions and 2,104
slices, with 0 unsupported and 0 unavailable. The stdlib alone has 1,711
functions and 1,777 slices: 896 translate exactly and 881 approximately.

**Runtime.** About 2.5 s of analysis for the stdlib, and under 0.7 s for
each OSS library.

**SL002.** On real code, 2 candidates remain after the fixes. Both are
refuted false positives, and precision is 0 of 2 (0 of 9 before the fixes).
None of the 9 confirmed real omissions reaches `structured_possible`.
SL002 is therefore informational.

**SL001 `clause_conflict`.** It has 0 real-code candidates, so real-code
precision is unmeasured (0/0). On the fixtures it detects 4 of 4 with 0
false positives. The overlap tag blocks `pick/1`, and the reachability
check blocks the redundant-clause fixture `shadowed/1`.

**Recall on the 9 known real omissions.** 0 gated, 2 reported
(`Ecto.Query.Builder.Join.escape/3` and `quoted_type/2`, both as
`possible_domain_escape`). The remaining 7 are `unknown`, mostly because
inference is top-only.

**Body backend experiment** (EXPERIMENTS.md "Body backend experiment",
reports in `bench/corpus/reports/body/`). The body is type-checked under
each spec slice's domain through the `warnings/7` hook, on a patched
`c24c235` build (`bench/corpus/warnings7.patch`).
- Gating recall on the 9 known omissions goes from 0 to 1
  (`Ecto.Query.Builder.quoted_type/2`). Reported recall stays 2 of 9.
- It found one new real omission, `Ecto.Changeset.apply_changes/1`
  (report-only).
- It added 2 fixture false positives, 1 after the redundancy guard
  (`display/1`).
- It added no false positive on 297 real-code slices (decimal, plug, ecto).
- 18 obligations move from `unknown` to `none`, but only 5 are
  established (`U(D)` within `S_lo`: `Plug.Conn.get_cookies/1`,
  `get_resp_cookies/1`, `Ecto.put_meta/2`, `Ecto.Changeset.constraints/1`,
  `validations/1`); the other 13 (11 `Plug.Conn` struct updates,
  `add_error/4`, `prepare_changes/2`) have inexact spec returns and are
  compatible at available precision only. The reports now record
  `established` and `return_exact` per mode.
- Each slice costs about one module re-check: 1.7 s of body calls over
  decimal, plug and ecto, against 1.2 s for the whole signature analysis.
- The 8 misses: 5 are top-only returns (through helpers analysed under
  default domains: `Decimal.compare/2`, `cmp/2`; through generic
  `Enum`/`Map` calls: `Plug.Conn.Query.decode/4`, `Ecto.Repo.Assoc.query/4`,
  `Ecto.Repo.Preloader.query/7`); 2 are not top-only but leave only an
  uncounted component (`Ecto.Changeset.apply_action/2`, a subtraction
  payload through `apply_changes/1`; `Plug.Conn.merge_private/2`, a
  negated struct field through `Enum.into/2`), with input approximation on
  top; 1 is input approximation (`Ecto.Query.Builder.Join.escape/3`).
- Decision: **not adopted** (DESIGN sections 7 and 11).

**Stdlib before and after the review fixes.** Function classes are
unchanged except for `DateTime.from_iso8601/2,3`, which moved from
`unknown` to report-only `possible_domain_escape` because of the F1
widening check. That is a `float()` offset from arithmetic, the known
false-positive shape.

`mix spec_lint --ci` on the stdlib:

| | Findings | Gating | Exit |
| --- | --- | --- | --- |
| Before | 31 SL002 | 0 | 0 |
| After | 33 SL002 | 0 | 0 |

Unknown obligations on the stdlib, by reason: top_only 796,
no_counted_component 239, near_top 29.

**Fixtures.** 25 of 25 classes are as expected under both
`require_static_return` settings.

| `require_static_return` | Detected | Suppressed | False positives | True negatives |
| --- | --- | --- | --- | --- |
| `false` | 9 | 2 | 0 | 14 |
| `true` | 3 | 8 | 0 | 14 |

## Decisions

Each decision is recorded in DESIGN; the section is given in parentheses.

- **SL002 is informational** (sections 4 and 11, Phase 0 and the Phase 1
  rerun). It is reported in both profiles and gated only by
  `--warnings-as-errors`. It will be revisited when at least 10 candidates
  have been reviewed, precision is at least 80%, and at least 3 omissions
  are confirmed.
- **`clause_conflict` gates in both profiles** (section 4). The
  unreachable-clause prerequisite is approximated from the stored clause
  domains (3.1 step 7). A possibly shadowed clause is blocked. The check
  over-blocks guarded clauses: 23 stdlib clauses are flagged, none of them
  a conflict.
- **`require_static_return` defaults to `false`** (section 4). The measured
  cost of `true` is lost recall on the gating class, with no precision
  gain.
- **SL001 gating prerequisites** are: no `unsupported_construct` loss, no
  overlap tag (certain or unknown), no arrow in the return, and no
  argument with an `arrow_polarity` loss (sections 4 and 6).
- **Fingerprints** hash the translated bounds and the normalised loss
  records, not the raw spec AST (9.1). Cosmetic spec edits therefore keep
  acknowledgements. Refinements the lattice erases inside a type are not
  distinguished.
- **Stale detection only covers analysis that happened** (section 9). It
  never runs on partial or incomplete runs, never covers rules that did
  not run, and never covers slices or modules that are now unsupported or
  unavailable.
- **Coverage is independent of rule selection**, and
  `--warnings-as-errors` never changes SL008 (sections 4 and 9.1).
  `fail_on_regression: false` exempts regressions only. A slice that was
  never compared still needs an acknowledgement (9.1).
- **An unsupported checker chunk** (`unsupported_chunk`) is a preflight
  failure: the run is incomplete, CI exits 2, and it cannot be
  acknowledged (5.1).
- **SL006 ignores top-only and near-top inference.** Such cases are
  recorded in the ledger as unknown (section 4).
- **The evidence class list is the one implemented** (section 4). It adds
  `clause_conflict`, `possible_gradual`, `unexpected_return`,
  `unsupported` and `unavailable`.
- **Deferred:** inline suppression, `--no-compile` and path filters
  (section 8).

## Open findings from external review (2026-09-28)

None. Both reviews are closed; the second one is listed under "Delivered
in this phase". One item is left to the maintainer: two earlier commits
(`c4a8e18`, `ac3a75b`) carry a different `Co-Authored-By` trailer than the
review expected, and correcting them would rewrite published history.

## Delivered in this phase (second external review)

Every finding has a regression test; DESIGN 9.1 records the decisions.

1. **An ebin that lost its BEAM files passed CI as "0 specs" (high).**
   `SpecLint.Project.check_build_paths/1` returns
   `{:error, :missing_beams}` when a module the build lists has no BEAM
   file: the Elixir compile manifest of a Mix project (Mix does not rebuild
   the BEAM files, its manifest says the build is up to date), or else
   `<app>.app`. The run is a configuration error (exit 2). As a second
   line, a `compared` baseline entry whose slice is absent from the whole
   inventory is a stale inventory entry. Tests: `SpecLint.CoverageTest`
   "an ebin missing BEAM files its .app lists ...",
   `SpecLint.Integration.BuildAndCoverageTest` (BEAM files deleted with
   and without the `.app` file: exit 2).
2. **A report-only SL001 in the baseline suppressed it once it gated
   (medium).** Each baseline finding records its blocked prerequisites
   (`"blocked"`); an entry written blocked does not acknowledge an SL001 or
   SL003 issue whose prerequisites are now met. The issue is new and the
   entry is listed under `gate_changed` (console and JSON). Test:
   `SpecLint.BaselineTest` "a report-only finding in the baseline does not
   acknowledge it once it gates".
3. **Regeneration while a module or slice was unavailable dropped its
   acknowledgements (medium).** `Baseline.build/5` keeps the previous
   findings of slices and modules that are now unsupported, unavailable or
   unanalysed (the rule stale detection uses), and the compared inventory
   entries of modules unavailable as a whole. Test: `SpecLint.BaselineTest`
   "regenerating while a module is unavailable keeps its
   acknowledgements".
4. **Deleting an override of a `use`-injected default was a false
   `spec_removed` (medium).** An export whose debug-info definition carries
   `from_super: false` (the compiler's marker for an overridable default
   that was not overridden) is a deleted user definition, not a regression.
   Test: `SpecLint.CoverageTest` "deleting an override of a use-injected
   default is not a regression" (a `use GenServer` module).
5. **Losing one overload passed CI although DESIGN 9 says it is a
   violation (medium, and the low finding on the same point).**
   Implemented as section 9 says: a function with fewer in-scope spec
   clauses than a slice the baseline lists as compared gets an `unanalysed`
   entry (`spec_clause_removed`), a regression. The first fix's exemption
   is removed from DESIGN 9.1, the Coverage moduledoc and the README. Test:
   `SpecLint.CoverageTest` "removing one overload while another stays
   analysed is a regression" (one overload removed, and overloads merged).
6. **Overclaims in the body-experiment write-up (two medium findings).**
   "18 obligations established" is restated as 5 established and 13
   compatible at available precision, from the new `established` and
   `return_exact` fields (reports regenerated; no other field changed).
   "7 of the 8 misses are top-only" is restated as 5 top-only and 2 not
   top-only; "together they cover 7 of the 8" is restated as removing one
   blocker in 7, with at most 4 (realistically 3) gateable.
7. **Low findings.** An explicit `--baseline` or `baseline:` path that does
   not exist is a configuration error (exit 2; `SpecLint.RunTest` and the
   build integration test). `mix spec_lint.baseline --output PATH` runs
   against `PATH` (integration test). `pending_reconciliation` is cleared
   when a kept entry's own adapter is the running one (`SpecLint.BaselineTest`
   "a pending entry regenerated under its own adapter acknowledges again").
   The omission fixtures' claim is qualified to class and detection, with
   the reason differences of `apply_action/2` and `quoted_type/2` recorded
   in `bench/corpus/omissions/README.md`. `run.sh` and `body_run.sh` no
   longer need bash 4 (both regenerated the reports under `/bin/bash`
   3.2.57). The fork and branches holding `c24c235` and `b88a257a3` are
   documented, and the hook is committed as `bench/corpus/warnings7.patch`.
   The Phase 0 triage probes are committed under `bench/triage/`, and every
   scratchpad path in EXPERIMENTS.md is marked non-durable. The
   integration tests use `SpecLint.ProjectFixture` (system temporary
   directory). README documents `lost_analysis` in the ledger. This file's
   counts are corrected.

## Fixed findings from the first external review

Each fix has end-to-end regression tests; DESIGN section 9.1 records the
decisions.

0. **Benchmark evidence lived only in the session scratchpad.** It is now a
   reproducible bundle under `bench/corpus/`: pinned corpus revisions and
   commands (`README.md`), `run.sh` to regenerate the normalised reports in
   `reports/` (all regenerated at this revision; `stdlib.json` stored in
   reduced form), and the nine real omissions as executable reproducers
   (`test/support/omission_fixtures.ex`, `test/spec_lint/omissions_test.exs`,
   `bench/corpus/omissions/README.md`). The test pins the current class of
   each: 7 `unknown` and 2 `possible_domain_escape`, gating recall 0 of 9.

1. **Spec removal bypassed coverage regression (high).** Coverage now
   compares the baseline inventory with the current exports
   (`SpecLint.Coverage.lost_analysis/2`). A compared slice whose function
   is still exported but has no spec in scope is an `unanalysed` entry
   (`spec_removed`), an SL008 finding and a regression (exit 1 in CI, or a
   coverage violation naming the MFA when SL008 is not selected). A deleted
   or no longer exported function is not a regression. Regenerating the
   baseline acknowledges the removal. Tests:
   `SpecLint.CoverageTest` "removing a @spec while keeping the function is
   a coverage regression" and "a spec that is now out of scope ...", and
   `SpecLint.Integration.BuildAndCoverageTest` (consumer project,
   `mix spec_lint --ci` exits 1 with SL008 on `Consumer.greet/1`).
2. **Old-adapter acknowledgements carried across a regeneration (medium).**
   Baseline findings are checked for adapter compatibility per entry.
   Entries of disabled rules from another adapter are kept with
   `"pending_reconciliation": true`, never count as baselined when the rule
   is re-enabled, are never stale, and are reported under
   `pending_reconciliation`. Tests: `SpecLint.BaselineTest` "a disabled
   rule's entries from another adapter are pending, never baselined" (the
   review's repro), "an entry without its own adapter inherits the
   file's", and "adapter change with a rule off, end to end".
3. **Unsupported sibling overloads dropped from overlap (medium).** An
   unsupported sibling makes a slice's overlap `unknown`, which blocks
   SL001 and SL003, unless the upper bounds of whatever of its arguments
   translate (`SpecLint.Translate.argument_bounds/2`) show it disjoint.
   Tests: `SpecLint.CompareTest` (three comparator and analysis tests),
   `SpecLint.TranslateTest` "argument bounds of an unsupported slice",
   `SpecLint.RulesTest` "SL001 with an unsupported sibling overload is
   gated only when shown disjoint".
4. **Missing build directory reported as zero specs.**
   `SpecLint.Project.check_build_paths/1` returns
   `{:error, :missing_build_path}` for an owned app whose ebin does not
   exist; the run is a configuration error (exit 2). An existing empty
   ebin exits 0 with "0 specs checked". Tests: `SpecLint.CoverageTest`
   "build directories", and `SpecLint.Integration.BuildAndCoverageTest`
   (exit 0 on an empty ebin, exit 2 on a removed one).

Wording: the analysis is conservative with tested gating prerequisites and
documented limitations. "Sound" is not claimed.

## Known limitations

- **Signature backend only.** There is no body analysis, so SL007 and
  `analysis: :bodies` exit 2. The body-backend experiment measured what
  body analysis would add (1 of 9 known omissions gated) and it was not
  adopted (EXPERIMENTS.md "Body backend experiment"). The binding
  constraints are compiler inference (helpers under default domains,
  generic `Enum`/`Map` signatures) and translation input approximation.
  Gating recall on the frozen evaluation (inventory version 2) is 3 of 18
  witnessed omission families (0 of the 8 original hand-found ones).
- **Spec slices are positional.** Removing any one overload of a
  multi-clause spec is reported against the last slice index
  (`spec_clause_removed`), and reordering spec clauses changes the
  fingerprints of the findings on them.
- **Missing BEAM detection relies on a Mix internal.** The compile
  manifest is read with `Mix.Compilers.Elixir.read_manifest/1` of the
  pinned toolchain. Without it only `<app>.app` is checked, which Mix
  rewrites from the BEAM files present, so deleting both the BEAM files
  and the `.app` file is then caught only as stale inventory entries
  (a warning), not as exit 2. `bench/run_on_ebin.exs` checks `<app>.app`
  only.
- **Gate state covers prerequisites, not profiles.** A baseline entry
  records the prerequisites that blocked it, not the profile it was
  written under: an SL006 acknowledged under `soundness` (report-only)
  still acknowledges it under `review` (gated). Entries written before
  this phase have no `blocked` field and acknowledge as before.
- **Top-only inference hides most evidence.** On the stdlib, 913 of 1,777
  slices are top-only.
- **Two qualified compiler revisions.** Every internal used (`Descr`, the
  `ExCk` layout, `apply_infer/2`) is `@moduledoc false` and can change
  without notice. Any other compiler is reported as unsupported, and so is
  a qualified revision whose internals fail a capability probe. On
  upstream `648b2a9`, `for ... into:` with a collectable that may be a
  bitstring or a list stores an unsound signature, which can make SpecLint
  gate a correct spec (audit row 19).
- **Reachability is approximated.** The compiler's redundancy verdict is
  not in the chunk, so the shadowing check over-blocks clauses whose
  earlier clauses are narrowed by guards.
- **Translation losses.** `integer_refinement_erased` makes most struct
  APIs (`Decimal.t()`, `Plug.Conn.t()`) input-approximate. Opaque remote
  types are `term()` unless `expand_opaque` is on. Overlapping overloads
  follow no validated semantics and are never gated.
- **Real-code precision of `clause_conflict` rests on few gates**: all 27
  release gates (3 functions) survived independent refutation, which is
  too few to bound a rate. The first confirmed false positive reopens its
  gating decision.
- **Minor gaps.** Message printing of nested negations is simplified, but
  it is presentation only. A module whose checker chunk version mismatches
  but that has no in-scope specs is not flagged. Umbrella aggregation
  is covered by `SpecLint.Integration.CiQualificationTest` (a two-child
  umbrella consumer). With no debug info the console and the summary line
  still say "0 specs checked: no eligible specs found" next to the SL008
  `missing_metadata` findings; the findings and the exit code are right,
  the wording is misleading.

## Next steps

**Next investment (per the external review): compiler inference, not a
body backend.** Body analysis did not improve recall materially (gated
0 to 1 of 9, reported 2 to 2), so it is not implemented or qualified. What
blocks the 8 misses is inference in the compiler; in the order of the
misses each would unblock (DESIGN section 11 has the same list):

1. **Parametric signatures for `Enum.map/2`, `Enum.reduce/3`,
   `Enum.into/2` and `Map.new/1`**: `Plug.Conn.Query.decode/4`,
   `Ecto.Repo.Assoc.query/4`, `Ecto.Repo.Preloader.query/7` (top-only
   today) and `Plug.Conn.merge_private/2`.
2. **Call-site-sensitive inference of local helpers and same-module
   callees**: `Decimal.compare/2` (the `error/4` macro and the private
   `handle_error/4`), `Decimal.cmp/2` (delegates to `compare/2`) and
   `Ecto.Changeset.apply_action/2` (through `apply_changes/1`).
3. **Recursive definitions inferred to a fixed point** instead of
   `dynamic()` at the self-call: `Ecto.Query.Builder.Join.escape/3`,
   `quoted_type/2`, and `unextract/3` under `Preloader.query/7`.
4. **Clause reachability per source clause in the checker chunk**: the
   23 over-blocked guarded stdlib clauses, and the body run's `name/1`
   fixture false positive.

Even with items 1 and 2, at most 4 of the 8 become gateable (realistically
3: `decode/4`, `Assoc.query/4`, `Preloader.query/7`), because input
approximation caps `Decimal.compare/2`, `merge_private/2` and
`apply_action/2` (and probably `cmp/2`). The follow-up experiment narrows the SpecLint-side recommendation:
a larger sound input lower bound alone cannot contain any of the 33
contributing stored clause domains in the nine fixtures, because none is
contained even in the input upper bound. Four fixture slices already have
exact input translation. See `bench/corpus/precision_ceiling.md`; this is
not a result about refined body signatures or all OSS code.


The expanded cohort changes the immediate experiment priority. Before a
broad compiler investment, investigate whether translation-loss prerequisites
can be qualified per clause: `Ash.Page.page_opts/1` has a witnessed literal
input/return omission, but an arrow elsewhere in the input union blocks its
SL001 gate. Prove that the relevant clause bounds remain sound, retain
contravariant-arrow and overlap negative controls, and validate on a fresh
holdout. Do not globally remove `no_arrow_polarity_argument`. The other two
witnessed Ash reports are SL002 and do not justify gating that rule.

Then, in order:

1. **Upstream API request.** Use the proposal in EXPERIMENTS.md "Minimal
   compiler API": `Module.Types.infer_under_domains/7` (only the targets
   and what they reach), signatures in stored form, reachability per
   source clause, diagnostics, and a `Module.Types.capabilities/0`
   version. Also ask for a stable, documented reader for the `ExCk`
   chunk and for the compile manifest's module list.
2. **SARIF output** next to the console and JSON reporters. Map rule IDs,
   evidence and fingerprints (as `partialFingerprints`) and the baseline
   state (as `baselineState`).
3. **Caching under `_build`**, keyed as DESIGN 9 "Cache keys" says (chunk
   contents, resolved remote types, tool and adapter versions, config
   digest; not the BEAM md5). Keep JSON byte identical.
4. **Additional adapters.** One module per qualified compiler revision
   (the next 1.21 development tips, then 1.21.0), each with the
   differential tests for `apply_infer/2`, a published support matrix and
   the stdlib regression.
5. Stdlib dogfooding: migrate the prototype's 68-entry exclusion list to a
   fingerprinted baseline.
6. Re-run the SL002 experiment whenever the classifier or containment
   changes (DESIGN section 12).
7. Recursion, mutual recursion and widening fixtures (DESIGN 7 item 5)
   were not built, because the body backend was not adopted; build them
   if it is revisited.
