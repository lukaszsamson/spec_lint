# Hardening campaign 1 — 2026-09-29

**Pre-dependency-fix evidence, not final release qualification.** A later
adversarial probe found that an owned c24c235 project can still consume a
stale dependency built by diagnostic-only `648b2a9`, producing a false
SL003 gate for code that returns `:ok`. The artifact checks in this campaign
do not establish dependency provenance across builds of the same compiler
line. These reports are retained unchanged as the baseline before that fix;
a new freeze and replay are required after the fix.

Measured implementation revision `90cecbfd6992e0ed9aaaac0766325b69ba6fce1c`,
source SHA-256 `430e14494fe86c0dc28f1df73a3f58ecdf6904fd806e9b6d82622daafbedd299`.
The campaign ran from a clean isolated clone, with freshly compiled tool and
dependency artifacts in a separate build directory for each compiler. It
reused the frozen, qualified corpus inputs from release campaign 2 without
modifying their source or compiled artifacts. Both exact compiler preflights
permitted gating. No upstream `648b2a9` campaign certifies CI: that compiler
remains diagnostic-only.

The two compiler campaigns ran sequentially after the Linux qualification
jobs became idle. All thirty product runs completed and met the committed
per-corpus budgets; budgets were enabled throughout. Each adapter has fifteen
product reports, input provenance records and resource measurements.

| Result | c24c235 | 1.20.4 (759443e) |
| --- | ---: | ---: |
| Compared spec slices | 4,204 | 4,170 |
| Findings | 63 | 65 |
| Gates | 9 | 9 |
| Gate diff versus release-2 | 9 unchanged | 9 unchanged |
| Exact replay (`all_unchanged`) | true | true |
| Budget checks | 15/15 passed | 15/15 passed |
| Absinthe wall time | 75.68 s | 73.10 s |
| Absinthe maximum RSS | 6,211,731,456 bytes | 5,265,080,320 bytes |
| Witnessed families: gated / reported / silent | 3 / 8 / 7 | 3 / 8 / 7 |

Absinthe's frozen budget is 90 seconds and 8,256 MiB maximum RSS. The run
measurements use macOS `/usr/bin/time -l`, around the product VM, on the
existing Apple M2 Pro / OTP 28.5.0.1 qualification host. This is the macOS
corpus campaign; it does not claim a complete Linux corpus replay.

`*.replay.json` checks equality of every report key except `beams`, the
existing allowance for build-path-dependent artifact identities. In this
campaign even the BEAM records are unchanged: every normalized product
report is byte-identical to release-2. `input-audit.json` additionally
verifies each source revision, clean state, lockfile, compiler identity,
compiler source and compiled corpus artifact hash/count against release-2.
The intentional provenance changes are the tool revision and tool source
SHA-256; they identify the measured hardening tree rather than historical
release-2. `*.gates.json` preserves every gate and its fingerprint unchanged.
`detection.json` comes from the strengthened cohort validator, which accepts
both complete, unfiltered, consistent report sets against inventory v2.

Reproduce from this implementation using the existing frozen inputs (set
portable paths for their locations; do not resolve replacement dependency
versions):

```sh
# Under each exact compiler, with its matching frozen corpus build root:
export MIX_ENV=test SPEC_LINT_PRODUCT_ONLY=1
export MIX_BUILD_PATH="$SCRATCH/tool-build/$ADAPTER/test"
export SPEC_LINT_CORPUS_OUT="$SCRATCH/reports/$ADAPTER"
export SPEC_LINT_CORPUS_BUILD="$FROZEN_BUILD"
export ELIXIR_DIR="$QUALIFIED_COMPILER"
export SPEC_LINT_COMPILER_REPO="$QUALIFIED_COMPILER_SOURCE"
# 1.20.4 additionally uses its frozen stdlib source and manifest.
SPEC_LINT_OSS="$ORIGINAL_SOURCES" SPEC_LINT_CORPUS_MANIFEST="$ORIGINAL_MANIFEST" \
  bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_OSS="$EXPANSION_SOURCES" SPEC_LINT_CORPUS_MANIFEST="$EXPANSION_MANIFEST" \
  bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
bench/corpus/compare_replay.sh "$SCRATCH/reports/$ADAPTER" "bench/corpus/reports/release-2/$ADAPTER"
bench/corpus/gate_diff.sh "$SCRATCH/reports/$ADAPTER" "bench/corpus/reports/release-2/$ADAPTER"
elixir bench/evaluation/detection.exs "$ADAPTER=$SCRATCH/reports/$ADAPTER"
```

The replay command's process exit alone is not an equality verdict: inspect
`all_unchanged` in its JSON output. Campaign logs retain the actual product
exit statuses (1 for the known gated findings, 0 otherwise); the runner
accepts them only when they match the complete report.
