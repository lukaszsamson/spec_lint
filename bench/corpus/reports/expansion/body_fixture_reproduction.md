# Reproduce the body fixture measurement

The adjacent `body_fixtures.json` and `body_fixtures.provenance.json` came
from one run of the compiler at `c24c23538d521d25edd6a9a7a66fc5206caab70e`
with `bench/corpus/warnings7.patch` applied. The provenance records the
loaded `Module.Types` BEAM hash, patch hash, 19 fixture BEAM hashes as one
artifact hash, and the SpecLint source hash. Its fixture ebin path was a
temporary directory and is no longer present. Recreate it with the commands
below from the SpecLint repository root:

```sh
export ELIXIR_BODY=/path/to/elixir-at-c24c235-with-warnings7-patch
test "$(git -C "$ELIXIR_BODY" rev-parse HEAD)" = \
  c24c23538d521d25edd6a9a7a66fc5206caab70e

MIX_ENV=test mix compile
run_dir=$(mktemp -d)
trap 'rm -rf "$run_dir"' EXIT
mkdir -p "$run_dir/fixtures_ebin"

"$ELIXIR_BODY/bin/elixirc" -o "$run_dir/fixtures_ebin" \
  test/support/fixtures.ex test/support/omission_fixtures.ex \
  test/support/experiment_fixtures.ex

"$ELIXIR_BODY/bin/elixir" -pa _build/test/lib/spec_lint/ebin \
  bench/body_experiment.exs -- --ebin "$run_dir/fixtures_ebin" \
  --prefix SpecLint.OmissionFixtures \
  --prefix SpecLint.ExperimentFixtures --label fixtures \
  --out "$run_dir/body_fixtures.json"

SPEC_LINT_ROOT="$PWD" SPEC_LINT_RAW_DIR="$run_dir" \
  SPEC_LINT_REPORT_LIMIT=50000000 \
  bench/corpus/normalise_report.sh "$run_dir/body_fixtures.json" \
  bench/corpus/reports/expansion/body_fixtures.json

SPEC_LINT_ELIXIR_BIN="$ELIXIR_BODY/bin/elixir" \
  SPEC_LINT_COMPILER_REPO="$ELIXIR_BODY" \
  SPEC_LINT_COMPILER_PATCH="$PWD/bench/corpus/warnings7.patch" \
  bench/corpus/provenance.sh \
  bench/corpus/reports/expansion/body_fixtures.provenance.json \
  body_fixtures "$PWD" "$PWD" "$PWD" "$run_dir/fixtures_ebin"
```

The current report has 37 slices, zero unavailable body analyses, and one
additional gate among the nine omission reproducers (`quoted_type/2`). Across
all 36 fixture functions, signature to body counts are gates 4 to 5,
structured candidates 5 to 7, and reported findings 17 to 17. The legacy
`warn` count combines gates and candidates (9 to 12). Wall-clock cost fields
vary across runs; compare the outcome counts and the provenance hashes.
