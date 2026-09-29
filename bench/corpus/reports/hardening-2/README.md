# Hardening campaign 2 — 2026-09-30

Measured implementation: `1bb95947c709a467bc89a65ed61d5829c220086f`.
Source SHA-256: `3e1484003bde47d1278aa929a687ea4683f32a267d6f1b8f2657b84c7451d978`.
Both campaigns ran sequentially from a clean isolated clone, after the final
macOS quality lanes completed and the Linux jobs became idle. Tool artifacts
were compiled separately under each exact compiler. Frozen corpus source,
locks, compiler inputs and compiled corpus/dependency artifacts were reused
unchanged; budgets remained enabled. All thirty product runs completed and
met their committed wall-time and maximum-RSS budgets.

| Result | c24c235 | 1.20.4 (759443e) |
| --- | ---: | ---: |
| Compared spec slices | 4,204 | 4,170 |
| Findings | 63 | 65 |
| Gates | 9 | 9 |
| Gate diff versus release-2 | 9 unchanged | 9 unchanged |
| Exact replay (`all_unchanged`) | true | true |
| Normalized reports byte-identical to release-2 | 15/15 | 15/15 |
| Budget checks | 15/15 passed | 15/15 passed |
| Absinthe wall time | 75.71 s | 67.99 s |
| Absinthe maximum RSS | 6,043,353,088 bytes | 4,553,474,048 bytes |
| Witnessed families: gated / reported / silent | 3 / 8 / 7 | 3 / 8 / 7 |

Absinthe's frozen budget is 90 seconds and 8,256 MiB maximum RSS. These are
macOS `/usr/bin/time -l` measurements around the product VM on the Apple M2
Pro / OTP 28.5.0.1 qualification host. No upstream `648b2a9` run certifies CI;
that build remains diagnostic-only. This campaign is not a complete Linux
corpus replay; the Linux Absinthe consumer's 6 GiB OOM remains a failed,
unqualified result, documented separately.

## Evidence and interpretation

- `*.release-2.replay.json`: exact equality of every report key except the
  allowed build-path-dependent `beams` field. In this campaign even that
  field is unchanged: all thirty normalized reports are byte-identical.
- `*.release-2.gates.json`: each of the eighteen gate observations retains
  its complete gate record and fingerprint; none is added, removed or
  changed. These are nine gates on three functions per compiler, not an
  estimate of a general false-positive rate.
- `input-audit.json`: all thirty source revisions, clean states, locks,
  compiler source identities, compiler code/checker identities and compiled
  artifact hash/count sets match `hardening-1`. The tool revision and source
  hash intentionally identify the final dependency fix and generator-order
  policy, rather than that pre-fix baseline.
- `detection.json`: the strengthened validator accepts complete, unfiltered,
  consistent compiler/config/tool cohorts against frozen inventory v2.
  Detection remains three gated, eight additionally reported and seven
  silent omission families out of eighteen.
- Per-corpus provenance, reports and resource JSON, plus campaign logs,
  retain the inputs, actual product exit statuses and budget outcomes.

## Public task qualification is separate from raw corpus input provenance

The corpus runner uses explicit ebin research inputs whose full compiler and
dependency provenance was established externally and checked against the
frozen reference. Unrecorded raw `SpecLint.Run` inputs cannot reconstruct
who compiled them. A successful raw corpus replay alone does not qualify
the public Mix task's dependency lifecycle.

The final public task was separately checked by the full integration suites,
production self-checks and independent dependency probes. Build-record v3
binds dependency artifacts used for inference. The normal cached
`648b2a9` dependency → c24c235 consumer false-gate witness is corrected;
a checker-only change with unchanged code MD5 forces both dependency and
caller rebuilding, recorded raw runs reject changed dependency inputs, and
a clean subsequent task run performs no compilation. Unsupported custom
compiler pipelines and unverified orphan outputs fail closed. The first two
built-in source generators may occur in either order, while artifact stages
remain `:erlang`, `:elixir`, `:app`. This does not allow custom compilers,
aliases or reordered artifact stages; `file_system` consumers are refused.

See `../../toolchain/quality-1bb9594/`,
`../../toolchain/dependency-provenance-review.md`,
`../../toolchain/generator-order-review.md` and
`../../toolchain/linux-results.md` for the exact qualification scope.
The final macOS lanes passed 497/499 tests (fork/release), strict Credo,
format and Dialyzer, and both production self-checks compared 419 specs with
zero findings and complete exit 0. One diagnostic-only public task test was
skipped in each gating lane and runs separately on the actual diagnostic
compiler. Earlier obsolete-record/setup and shared-checkout fixture failures
are retained as failed attempts, not counted as passes.

## Reproduction

Set portable paths to the existing frozen source/build roots and exact
qualified compiler inputs. Do not substitute freshly resolved dependencies.

```sh
export MIX_ENV=test SPEC_LINT_PRODUCT_ONLY=1
export MIX_BUILD_PATH="$SCRATCH/tool-build/$ADAPTER/test"
export SPEC_LINT_CORPUS_OUT="$SCRATCH/reports/$ADAPTER"
export SPEC_LINT_CORPUS_BUILD="$FROZEN_BUILD"
export ELIXIR_DIR="$QUALIFIED_COMPILER"
export SPEC_LINT_COMPILER_REPO="$QUALIFIED_COMPILER_SOURCE"
# 1.20.4 also sets SPEC_LINT_STDLIB_SOURCE to its frozen source checkout.
SPEC_LINT_OSS="$ORIGINAL_SOURCES" SPEC_LINT_CORPUS_MANIFEST="$ORIGINAL_MANIFEST" \
  bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS="$EXPANSION_SOURCES" SPEC_LINT_CORPUS_MANIFEST="$EXPANSION_MANIFEST" \
  bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
bench/corpus/compare_replay.sh "$SCRATCH/reports/$ADAPTER" "bench/corpus/reports/release-2/$ADAPTER"
bench/corpus/gate_diff.sh "$SCRATCH/reports/$ADAPTER" "bench/corpus/reports/release-2/$ADAPTER"
elixir bench/evaluation/detection.exs "$ADAPTER=$SCRATCH/reports/$ADAPTER"
```

Inspect `all_unchanged` in the replay JSON: the comparison process exit alone
is not an equality verdict. Product exit 1 for the known gates is accepted
only when it matches the complete report; missing, partial, killed and
inconsistent results are refused by the campaign runner.
