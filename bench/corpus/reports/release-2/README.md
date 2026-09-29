# Release campaign 2 (Milestone 5): the reviewed tree against the frozen budgets

Release campaign 1 (`../release-1/`, tool `06b7496`) was followed by the
Milestone 5 review, whose fixes changed `lib/` (crash handling) and the
corpus tooling, both inside the frozen `source_sha256`. So the release is
of a new freeze, and this campaign replays it: the same fifteen corpora
(and the fixture corpus), the same compiler builds and corpus builds, one
corpus at a time, with the budgets frozen from campaign 1 enforced. It is
the independent check of those budgets (campaign 1 derived them from its
own first run) and of the reviewed tree's reports.

## Frozen implementation

| | |
| --- | --- |
| Tool revision | `58fe1ddf34d23d22d3048cceb09a2d60e8d9342e` (M6 preparation: upstream submission package) |
| `source_sha256` | `26c90fa829b7277e88a6d8c26bcb4a67acc5539ae5c3c51c4a969dd61948a9eb` (`provenance.sh`) |
| Worktree | a clean `git worktree` of that commit; every provenance file records `"dirty": false` and this digest |
| Configuration | the product default (`SPEC_LINT_PRODUCT_ONLY=1`, no product options), as in campaign 1 |
| Budgets | `../../budgets.json` as committed in campaign 1 (not re-derived) |
| Inventory | evaluation inventory version 2 (`5753b08`) |

The changes since `06b7496` that the digest covers: `9f42022` (an exit or
a crashed process is an internal failure, never exit 1), `0cd5d11`
(fail-closed corpus tooling, detection provenance check), `5753b08` (the
witness scripts of inventory version 2) and `58fe1dd` (the upstream
package's reproducers and patch, which the digest's `bench/**` pattern
includes). None changes the analysis.

## Qualification of the frozen tree (`qualification/`)

Run on exactly the content of `58fe1dd` (staged tree, before the commit),
each compiler with its own `MIX_BUILD_PATH` and `SPEC_LINT_PLT_DIR`, with
`SPEC_LINT_OTHER_ELIXIR` (1.20.4 for the 1.21 builds, `c24c235` for
1.20.4) and `SPEC_LINT_UNSUPPORTED_ELIXIR` (1.19.4) set, so no
cross-compiler test is excluded and the 1.19 refusal test is not skipped:

| | `c24c235` | `648b2a9` | 1.20.4 |
| --- | --- | --- | --- |
| `mix format --check-formatted`, `mix credo --strict` | clean | clean | clean |
| `mix test` | 468 passed, 9 excluded | 468 passed, 9 excluded | 471 passed, 6 excluded |
| `mix dialyzer` | 0 errors | 0 errors | 0 errors |
| Self-check `mix spec_lint --ci` | 408 slices, complete, exit 0 | 408 slices, complete, exit 0 | 408 slices, complete, exit 0 |

The excluded tests are the other compiler line's adapter-pinned tests.
The counts include the 18 installation and upgrade tests
(`test/integration/release/`), which campaign 1's 439/439/442 did not.

## Replay results

`c24c235/`, `648b2a9/`, `1.20.4/`: per corpus `NAME.spec_lint.json`,
`NAME.provenance.json` and `NAME.resources.json`, plus `fixtures.json`,
`summary.json` (`compare_replay.sh` against `../release-1/` of the same
compiler), `struct_defaults.json`; `gates.json` (`gate_diff.sh` against
campaign 1) and `detection_v2.json` (`detection.exs`, inventory version 2).

- **Every product report is byte-identical to campaign 1** under every
  compiler (`summary.json`: `all_unchanged: true`, no differing key; `cmp`
  equal for all 45 files), and so is every fixture experiment report.
  The provenance files differ from campaign 1 only in `tool` (and, for the
  fixture corpus, in the hash of SpecLint's own ebin, which is the fixture
  corpus's code path).
- **Gates**: 27 (9 per compiler), all `unchanged` against campaign 1, none
  new, changed or removed; nothing new to refute
  (`../release-1/refutation.json` covers them: 0 false positives).
- **Struct defaults**: 7 findings per compiler, all seven gates of
  `Absinthe.Blueprint.Input.parse/1` (F16), as in campaign 1.
- **Detection** (inventory version 2): 3 gated, 8 reported, 7 silent of 18
  families under each compiler; `return_value` 2, 8 and 5 of 15.

| Adapter | Compared slices | Unknown obligations | Findings | Gates | Exit 1 (gates) |
| --- | ---: | ---: | ---: | ---: | --- |
| `1.21.0-dev+c24c235` | 4,204 | 3,113 | 63 | 9 | Absinthe, Ash, Oban |
| `1.21.0-dev+648b2a9` | 4,204 | 3,113 | 63 | 9 | Absinthe, Ash, Oban |
| `1.20.4+759443e` | 4,170 | 3,095 | 65 | 9 | Absinthe, Ash, Oban |

## Runtime and memory against the frozen budgets

Same method and machine as campaign 1 (`/usr/bin/time -l` around the
product run, one corpus at a time, nothing else running; Apple M2 Pro,
12 cores, 32 GB, macOS 26.7, OTP 28.5.0.1). **Every corpus under every
compiler is within its budget** (`NAME.resources.json`, `budget.within:
true`); `run.sh` would have exited 2 otherwise.

| Corpus | Wall s (c24c235; 648b2a9; 1.20.4) | Peak RSS MiB | Budget |
| --- | --- | --- | --- |
| absinthe | 57.2; 57.1; 58.0 | 6063; 6080; 5774 | 90 s, 8,256 MiB |
| ash | 3.40; 3.55; 3.90 | 317; 320; 307 | 10 s, 448 MiB |
| stdlib | 1.44; 1.36; 1.40 | 429; 422; 445 | 5 s, 576 MiB |
| tesla | 0.94; 0.96; 0.97 | 168; 165; 170 | 5 s, 256 MiB |
| the other eleven | 0.48-0.77 | 120-166 | 5 s, 256 MiB |

The budgets are post-hoc regression thresholds (campaign 1 derived them
from its own first run, so its "within budget" held by construction); this
campaign is the first run measured against them after they were frozen.
Absinthe's whole product run is 57-58 s, which also meets the Milestone 1
target of 60 s; the Absinthe budget stays at 90 s, because a threshold 3%
above the measured maximum would fail on ordinary noise.

## Regenerate

As `../release-1/README.md`, "Regenerate", from a clean worktree of
`58fe1dd` with the same builds and without deriving budgets. Then, from
`bench/corpus/reports`:

```sh
../compare_replay.sh release-2/REV release-1/REV > release-2/REV/summary.json
../gate_diff.sh release-2/REV release-1/REV          # combined into gates.json
elixir ../../evaluation/detection.exs "1.20.4+759443e=release-2/1.20.4" \
  "1.21.0-dev+648b2a9=release-2/648b2a9" "1.21.0-dev+c24c235=release-2/c24c235"
```

The reports were written outside the worktree and copied here;
`fixtures.json` and `fixtures.provenance.json` had the tool build path
replaced by `$TOOL_BUILD`, and `struct_defaults.json` its `reports` path
made relative (path strings only). The detection above was run from the
repository root with `bench/corpus/reports/` prefixed paths.
