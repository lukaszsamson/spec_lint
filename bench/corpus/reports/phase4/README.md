# Phase 4 regression replay

These are repeated measurements of the fifteen existing pinned corpora, not
fresh holdouts. Compare against `../expansion/clause_local/on/`. Each report
has source, BEAM, compiler and tool-source provenance beside it. The corpus
runner checks completion and process/report exit-code agreement.

Regenerate from the repository root with the pinned compiled checkouts from
`bench/corpus/README.md` and `bench/corpus/expansion.json`:

```sh
SPEC_LINT_PRODUCT_ONLY=1 SPEC_LINT_OSS="$ORIGINAL_OSS" \
  SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/phase4" \
  bench/corpus/run.sh stdlib jason decimal nimble_options mime plug ecto
SPEC_LINT_PRODUCT_ONLY=1 SPEC_LINT_OSS="$EXPANSION_OSS" \
  SPEC_LINT_CORPUS_MANIFEST="$PWD/bench/corpus/expansion.json" \
  SPEC_LINT_CORPUS_OUT="$PWD/bench/corpus/reports/phase4" \
  bench/corpus/run.sh req broadway oban phoenix_live_view ash nx absinthe tesla
```

The first Absinthe attempt was manually interrupted while investigating its
CPU/memory cost; `absinthe.interrupted.log` records that interruption, not a
clean scan or a product exit-code verdict. The historical independent product
scan took 345 seconds (`bench/corpus/holdout2_baseline.md`, Runtime). A diagnostic
rerun sampled translation, Descr construction and type printing. The new guard
check on `parse/1` takes under a millisecond in isolation. The interrupted
attempt therefore does not establish a performance regression. No translator
or compiler change was made in response; the final attempt allowed approximately 15 minutes but was also stopped.
`absinthe.final-interrupted.log` preserves that interruption. No final full
Absinthe report was produced. No controlled timing comparison is claimed.

## Results

`summary.json` compares the fourteen complete reports with their Phase 3
flag-on counterparts: 3,751 slices, unchanged ledgers, and two retained gates.
The display label change on clause findings predates Phase 4. Absinthe is
explicitly listed as an incomplete replay, not counted as a zero-finding run.

The scoped `absinthe.input.spec_lint.json` is **partial** and preserves all
seven known gate fingerprints. It used the same pinned Absinthe BEAMs:

```sh
MIX_ENV=test mix run bench/run_on_ebin.exs -- \
  --ebin "$EXPANSION_OSS/absinthe/_build/test/lib/absinthe/ebin" \
  --root "$EXPANSION_OSS/absinthe" --module Absinthe.Blueprint.Input \
  --ci --format json --output /tmp/absinthe.input.spec_lint.json
```

This command exits 1 because its seven findings gate. Its scoped provenance
is recorded separately. It does not establish unchanged coverage for all of
Absinthe. The full scan's performance needs a controlled follow-up.
