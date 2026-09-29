# Fifteen-corpus replay under Elixir 1.20.4 (Milestone 3)

The fifteen corpora of the Milestone 1 and 2 replays, recompiled with Elixir
1.20.4 (revision `759443e`, the precompiled release for OTP 29, run on
OTP 28.5.0.1) and analysed by the 1.20 adapter (`SpecLint.Compiler.V120`,
adapter id `1.20.4+759443e`). The audit of the compiler internals is
`../../toolchain/audit-1.20.4.md`. These are regression corpora, not
fresh holdouts.

| Path | What |
| --- | --- |
| `NAME.spec_lint.json`, `NAME.provenance.json` | the 1.20.4 product reports and their provenance |
| `c24c235/` | the same fifteen corpora under the 1.21 fork revision `c24c235`, with the same tool: the base of the comparison, and the check that the adapter refactoring changed nothing on 1.21 (`c24c235/summary.json`) |
| `comparison.json` | `../../toolchain/compare_lines.sh . c24c235`: per corpus, coverage, obligations and unknown reasons, loss kinds, findings by rule and evidence, gates, shared fingerprints and every ledger entry that differs |
| `baselines/1.20.4+759443e/`, `baselines/1.21.0-dev+c24c235/` | per-adapter baselines of the three corpora whose product run gates (Ash, Oban, Absinthe) |
| `fixtures.json`, `c24c235/fixtures.json` | the experiment report of the fixture corpus (evidence fixtures and omission stand-ins) under each line |

## Tool and toolchain

Every provenance file records the tool at commit `f364fa1` with `"dirty":
false`: the runs used a clean worktree of that commit (the main checkout
held untracked files of an unrelated experiment, `bench/clause_mapping/`,
which `provenance.sh` would have hashed as tool sources and reported as
dirty). The compiler is recorded as the `v1.20.4` tag
(`759443e724f55bf58e71c0603644e99058918d52`, a local clone used as
`SPEC_LINT_STDLIB_SOURCE` and `SPEC_LINT_COMPILER_REPO`), with the
path-independent identity `code_digest`
`cf42510c62e2725d02769af5996c808a8b597351db0d0dceb52ebf8a88febcb8`,
`exck_digest` `28bc01cf3075064bdebb88faf653a8ca8decb87c8c1bbd8e24c0e2e28a596d07`.
The corpus checkouts are the pinned revisions of `../../README.md` and
`../../expansion.json` (`../../toolchain/elixir-1.20.4.json` adds the
1.20.4 stdlib revision); they were verified clean before and after
compiling.

The fixture corpus is read from the tool's own build, which was outside
the checkout (`MIX_BUILD_PATH`); the normalisation does not know that
directory, so its prefix was replaced by `$TOOL_BUILD` in the two
`fixtures.json` and `fixtures.provenance.json` files after the run (a path
string only; no hash depends on it).

## Regenerate

`$E120` is the 1.20.4 installation (`~/.asdf/installs/elixir/1.20.4-otp-29`),
`$SRC` a checkout of the `v1.20.4` tag, `$BUILD` a new directory for the
corpus builds, `$ORIGINAL_OSS` and `$EXPANSION_OSS` the corpus checkouts
with their dependencies fetched. From a clean checkout of the tool:

```sh
export ASDF_ERLANG_VERSION=28.5.0.1 ASDF_ELIXIR_VERSION=1.20.4-otp-29
export MIX_BUILD_PATH=/path/to/spec_lint-build-1.20.4/test
export ELIXIR_DIR=$E120 SPEC_LINT_STDLIB_SOURCE=$SRC SPEC_LINT_COMPILER_REPO=$SRC
export SPEC_LINT_CORPUS_BUILD=$BUILD SPEC_LINT_PRODUCT_ONLY=1
export SPEC_LINT_CORPUS_MANIFEST=$PWD/bench/corpus/toolchain/elixir-1.20.4.json
export SPEC_LINT_CORPUS_OUT=$PWD/bench/corpus/reports/elixir-1.20.4

SPEC_LINT_OSS=$ORIGINAL_OSS bench/corpus/toolchain/compile_corpora.sh \
  jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS=$EXPANSION_OSS SPEC_LINT_CORPUS_MANIFEST=$PWD/bench/corpus/expansion.json \
  bench/corpus/toolchain/compile_corpora.sh req broadway oban phoenix_live_view ash nx absinthe tesla

SPEC_LINT_OSS=$ORIGINAL_OSS bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS=$EXPANSION_OSS bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla

SPEC_LINT_PRODUCT_ONLY=0 SPEC_LINT_OSS=/dev/null bench/corpus/run.sh fixtures

(cd bench/corpus/reports/elixir-1.20.4 && ../../toolchain/compare_lines.sh . c24c235 > comparison.json)
(cd bench/corpus/reports && ../compare_replay.sh elixir-1.20.4/c24c235 m1_review \
  > elixir-1.20.4/c24c235/summary.json)
```

`ASDF_ERLANG_VERSION` overrides the `.tool-versions` of Ash and Tesla
(which name OTP 28.1 and 28.5 with Elixir 1.19). The `c24c235/` reports
are the same `run.sh` calls under the fork build (`ELIXIR_DIR=~/elixir`,
no `SPEC_LINT_CORPUS_BUILD`: the checkouts' own `_build/test`, which the
fork compiled), and their BEAM MD5 values equal `../m1_review/`'s. The
per-adapter baselines add `SPEC_LINT_WRITE_BASELINE_DIR=.../baselines/ADAPTER`
for `ash oban absinthe`; `SPEC_LINT_BASELINE_DIR` applies them.

## Compilation

All fourteen OSS corpora compile under 1.20.4; none fails, so there is no
failed project to record. No project has more compiler warnings than under
648b2a9 (Ash 174 against 192, Phoenix LiveView 112 against 117, Broadway,
Oban, Req, Tesla and NimbleOptions one fewer, the rest equal; the compile
logs are in the build directory, not committed).

## Results

| Corpus | Exit (1.20.4 / 1.21) | Compared slices | Exact | Unknown obligations | Findings | Gates | Shared fingerprints |
| --- | --- | --- | --- | --- | --- | --- | --- |
| absinthe | 1 / 1 | 453 / 453 | 58 / 58 | 374 / 374 | 9 / 9 | 7 / 7 | 0 |
| ash | 1 / 1 | 992 / 992 | 512 / 512 | 803 / 803 | 12 / 12 | 1 / 1 | 2 |
| broadway | 0 / 0 | 30 / 30 | 11 / 11 | 25 / 25 | 0 / 0 | 0 / 0 | 0 |
| decimal | 0 / 0 | 46 / 46 | 0 / 0 | 28 / 28 | 2 / 2 | 0 / 0 | 0 |
| ecto | 0 / 0 | 165 / 165 | 26 / 26 | 137 / 137 | 4 / 4 | 0 / 0 | 0 |
| jason | 0 / 0 | 20 / 20 | 0 / 0 | 16 / 16 | 0 / 0 | 0 / 0 | 0 |
| mime | 0 / 0 | 5 / 5 | 3 / 3 | 0 / 0 | 0 / 0 | 0 / 0 | 0 |
| nimble_options | 0 / 0 | 5 / 5 | 4 / 4 | 5 / 5 | 0 / 0 | 0 / 0 | 0 |
| nx | 0 / 0 | 9 / 9 | 0 / 0 | 9 / 9 | 0 / 0 | 0 / 0 | 0 |
| oban | 1 / 1 | 130 / 130 | 40 / 40 | 115 / 115 | 2 / 2 | 1 / 1 | 2 |
| phoenix_live_view | 0 / 0 | 12 / 12 | 4 / 4 | 10 / 10 | 0 / 0 | 0 / 0 | 0 |
| plug | 0 / 0 | 86 / 86 | 18 / 18 | 79 / 79 | 0 / 0 | 0 / 0 | 0 |
| req | 0 / 0 | 87 / 87 | 14 / 14 | 75 / 75 | 0 / 0 | 0 / 0 | 0 |
| stdlib | 0 / 0 | 1,743 / 1,777 | 875 / 896 | 1,046 / 1,064 | 35 / 33 | 0 / 0 | 23 |
| tesla | 0 / 0 | 387 / 387 | 34 / 34 | 373 / 373 | 1 / 1 | 0 / 0 | 1 |
| **total** | | **4,170 / 4,204** | | **3,095 / 3,113** | **65 / 63** | **9 / 9** | **28** |

Every run is complete; no slice is unsupported or unavailable on either
line.

**The fourteen OSS corpora.** The whole ledger (coverage, the obligation
counts, the unknown reasons `top_only`, `no_counted_component` and
`near_top`, the loss kinds, and every entry's class, obligation,
translation and unknown reason), the findings with their rule, evidence,
slice, stored clause, message, prerequisites and baseline decision, the
gate decisions and the exit codes are identical on the two lines. Apart
from the fingerprints (below), the reports differ only in the adapter,
Elixir and checker versions, the BEAM identities and the build digest,
and in the rendered details of three non-gating findings (`Ash.load/3`,
`Ash.Test.refute_has_error/3`, `Absinthe.Phase.Init.run/2`), where the
compiler's printer lists the members of a slice's union in another order.
The details of every gate are identical (for example `Oban.Registry.via/3`:
"stored signature clause: #1 (term(), term(), not nil) -> dynamic({:via,
Registry, {Oban.Registry, term(), not nil}})"). **No gate differs**, so
there is no gate to triage. The two inference differences of the audit
(rows 34 and 35) do not reach these corpora's findings.

**The standard library** is a different library, 1.20.4's own. It has
34 fewer compared slices, and 77 ledger entries differ (38 slices exist
only under 1.21, 4 only under 1.20.4, 35 differ in class or unknown
reason). Neither line gates it. The informational SL002 findings that
differ:

| Finding | 1.20.4 | 1.21 | Why (stored signature, read from each build) |
| --- | --- | --- | --- |
| `DateTime.diff/3` | `possible_domain_escape` | unknown (`top_only`) | 1.20.4 infers `dynamic(float() or integer())` for the general clause, 1.21 `dynamic()`; the clause's third argument (`not :day and not :hour and not :minute`) escapes `System.time_unit()` |
| `NaiveDateTime.diff/3` | `possible_domain_escape` | unknown (`top_only`) | the same |
| `Float.round/2` | `possible_domain_escape` | `possible_input_approximate` | 1.20.4 stores a second clause `(float(), term()) -> none()` for the raising path (audit row 34), whose `term()` precision escapes the spec domain |

**Fingerprints.** Only 28 of the 65 1.20.4 fingerprints occur in the 1.21
reports: the fingerprint includes the canonical (structural) form of the
spec bounds and stored clauses, which differs between the lines wherever a
map or struct type is involved (none of Absinthe's nine, including its
seven gates). Findings are the same; their identities are not. A baseline
is therefore per adapter, as the adapter id already requires.

## Baselines per adapter

`baselines/ADAPTER/NAME.json` for the three corpora that gate: Ash (12
findings, 1 gate), Oban (2, 1) and Absinthe (9, 7) under each line.

Each was written by `run_on_ebin.exs --write-baseline` (the checks of
`mix spec_lint.baseline`) from a complete run under its adapter, and
checked by running the product again with it (`SPEC_LINT_BASELINE_DIR`):

| Run | Ash | Oban | Absinthe |
| --- | --- | --- | --- |
| 1.20.4 with its own baseline | exit 0, 12 baselined, 0 new | exit 0, 2 baselined | exit 0, 9 baselined |
| c24c235 with its own baseline | exit 0, 12 baselined, 0 new | exit 0, 2 baselined | exit 0, 9 baselined |
| 1.20.4 with the c24c235 baseline | exit 2, `adapter_mismatch`, 12 new | exit 2, 2 new | exit 2, 9 new |
| c24c235 with the 1.20.4 baseline | exit 2, `adapter_mismatch`, 12 new | exit 2, 2 new | exit 2, 9 new |

The mismatch runs are complete; exit 2 comes from the baseline ("baseline
... was written by adapter 1.21.0-dev+c24c235, the current adapter is
1.20.4+759443e; review and regenerate it with mix spec_lint.baseline").
Regenerating is not enough to carry acknowledgements across lines, since
the fingerprints differ: an entry must be reviewed again under the other
adapter. The two baselines of a corpus list the same findings (subject,
rule, slice, clause, evidence, blocked prerequisites); their fingerprints
differ except Oban's two and two of Ash's twelve.

## Known omission fixtures, per adapter

The classes pinned in `test/spec_lint/omissions_test.exs` are the same on
both lines:

| Fixture (original) | 1.21 | 1.20.4 |
| --- | --- | --- |
| `compare/2` (`Decimal.compare/2`) | unknown | unknown |
| `cmp/2` (`Decimal.cmp/2`) | unknown | unknown |
| `decode/2` (`Plug.Conn.Query.decode/4`) | unknown | unknown |
| `merge_private/2` (`Plug.Conn.merge_private/2`) | unknown | unknown |
| `apply_action/2` (`Ecto.Changeset.apply_action/2`) | unknown | unknown |
| `join_escape/3` (`Ecto.Query.Builder.Join.escape/3`) | possible_domain_escape | possible_domain_escape |
| `quoted_type/2` (`Ecto.Query.Builder.quoted_type/2`) | possible_domain_escape | possible_domain_escape |
| `assoc_query/4` (`Ecto.Repo.Assoc.query/4`) | unknown | unknown |
| `preloader_query/7` (`Ecto.Repo.Preloader.query/7`) | unknown | unknown |
| `page_opts/1` (`Ash.Page.page_opts/1`, clause-local) | clause_conflict, gated with the qualification | clause_conflict, gated with the qualification |
| `via/3` (`Oban.Registry.via/3`, clause-local) | clause_conflict, gated | clause_conflict, gated |

The classes with `require_static_return: true` and the top-only reasons
are the same too. Gating recall on the nine is 0 of 9 on both lines.

## Evidence fixtures, per adapter

`fixtures.json` (1.20.4) and `c24c235/fixtures.json` are the experiment
reports of the fixture corpus (`SpecLint.ExperimentFixtures`,
`SpecLint.Fixtures.*`, `SpecLint.OmissionFixtures.*`). Their totals (function,
slice and clause classes, with and without `require_static_return`) and the
accuracy block against `SpecLint.ExperimentFixtures.expected/0` are
identical. Five functions differ only in presentation: the printed stored
clauses or spec (union members in another order, for example the last
clause of `quoted_type/2`), and `apply_action/2`, whose raising path 1.20.4
stores as one more clause returning `none()` (audit row 34), with the same
class. The per-adapter expectations of the tests are in
`test/spec_lint/omissions_test.exs`, `clause_local_test.exs` and
`compiler_probe_test.exs` (tag `adapter:`).
