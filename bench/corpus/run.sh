#!/usr/bin/env bash
# Regenerates bench/corpus/reports/*.json (see bench/corpus/README.md).
#
#     SPEC_LINT_OSS=/path/to/oss [ELIXIR_DIR=~/elixir] bench/corpus/run.sh [corpus ...]
# Optional SPEC_LINT_CORPUS_MANIFEST is a JSON object from corpus name to
# {"revision": "40-character SHA", "app": "app_name", "project_subdir": "subdir"}.
# SPEC_LINT_CORPUS_OUT selects a separate output directory for wider scans.
# SPEC_LINT_ALLOW_UNPINNED=1 permits exploratory runs at other revisions.
# SPEC_LINT_PRODUCT_ARGS adds whitespace-separated options to the product run
# (for example --clause-local-qualification); the report's config records them.
# SPEC_LINT_PRODUCT_ONLY=1 skips the experiment report, for option comparisons
# that do not change it (the experiment has no product options).
#
# SPEC_LINT_OSS holds one checkout per library (jason decimal nimble_options
# mime plug ecto), each at the revision pinned in bench/corpus/README.md and
# compiled with `MIX_ENV=test mix deps.get && MIX_ENV=test mix compile`.
# ELIXIR_DIR is the Elixir checkout the toolchain was built from (default
# ~/elixir); its lib/*/ebin directories are the stdlib corpus.
#
# Corpora: stdlib jason decimal nimble_options mime plug ecto fixtures
# (default: all). Two files are written per corpus:
#   reports/NAME.json           the SL002 experiment report (bench/experiment.exs)
#   reports/NAME.spec_lint.json the `mix spec_lint --ci` report over the same
#                               ebins (bench/run_on_ebin.exs), not for fixtures
# Both are normalised. A report over 2 MB keeps its full normalised JSON in
# NAME.json.gz and writes a schema-checked summary to NAME.json. Per-corpus
# NAME.provenance.json records source, toolchain and compiled artifact hashes.
#
# Runs under bash 3.2 (the macOS system bash) and later: no associative
# arrays, and empty arrays are expanded with ${a[@]+"${a[@]}"} (set -u).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
oss="${SPEC_LINT_OSS:?set SPEC_LINT_OSS to the directory holding the corpus checkouts}"
elixir_dir="${ELIXIR_DIR:-$HOME/elixir}"
out="${SPEC_LINT_CORPUS_OUT:-$root/bench/corpus/reports}"
manifest="${SPEC_LINT_CORPUS_MANIFEST:-}"
raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
if [ -n "$manifest" ]; then
  jq -e 'type == "object" and all(.[]; (.revision | type == "string") and
    (.app == null or (.app | type == "string")) and
    (.project_subdir == null or (.project_subdir | type == "string")) and
    (.ebin == null or (.ebin | type == "string")))' "$manifest" >/dev/null ||
    { echo "invalid corpus manifest: $manifest" >&2; exit 2; }
fi

# revision NAME -> the pinned revision of a corpus checkout.
revision() {
  if [ -n "$manifest" ]; then
    local pinned
    pinned="$(jq -r --arg name "$1" '.[$name].revision // empty' "$manifest")"
    if [ -n "$pinned" ]; then echo "$pinned"; return; fi
  fi
  case "$1" in
    stdlib) echo c24c23538d521d25edd6a9a7a66fc5206caab70e ;;
    jason) echo 4ede42858eb19f80ec9e863aab52df466eab8608 ;;
    decimal) echo 92a28e6b9a103f2b52a22b3f772f7a2a34b7b1d5 ;;
    nimble_options) echo 825c05837f236c612c6ac2855735ec6cf7f2be69 ;;
    mime) echo 23dcc1593ccc49648e33b9ed3c03bd516795f6d9 ;;
    plug) echo 73404f851852a00ffb2014be95d4598900fa77b8 ;;
    ecto) echo 94d69279c517347ff0962b138f4ccd0556486ae2 ;;
    *) echo "unknown corpus: $1" >&2; exit 2 ;;
  esac
}

check_revision() {
  local actual expected
  expected="$(revision "$1")"
  actual="$(git -C "$2" rev-parse HEAD)" || exit 2
  if [ "$actual" != "$expected" ]; then
    if [ "${SPEC_LINT_ALLOW_UNPINNED:-0}" = 1 ]; then
      echo "warning: $1 is at $actual, expected $expected (exploratory override)" >&2
    else
      echo "unexpected revision for $1: $actual (expected $expected)" >&2
      exit 2
    fi
  fi
}

if [ $# -gt 0 ]; then
  corpora=("$@")
else
  corpora=(stdlib jason decimal nimble_options mime plug ecto fixtures)
fi

product_args=()
if [ -n "${SPEC_LINT_PRODUCT_ARGS:-}" ]; then
  read -r -a product_args <<<"$SPEC_LINT_PRODUCT_ARGS"
fi
product_only="${SPEC_LINT_PRODUCT_ONLY:-0}"

cd "$root"
mkdir -p "$out"
MIX_ENV=test mix compile >/dev/null

# ebins NAME -> sets ebins=(...) codepaths=(...) project_root
select_corpus() {
  ebins=()
  codepaths=()
  case "$1" in
    stdlib)
      project_root="$elixir_dir"
      source_repo="$elixir_dir"
      check_revision stdlib "$source_repo"
      for app in elixir eex ex_unit iex logger mix; do
        ebins+=("$elixir_dir/lib/$app/ebin")
      done
      ;;
    fixtures)
      # Only the fixture modules, staged as an app called "fixtures".
      project_root="$root"
      source_repo="$root"
      mkdir -p "$raw/fixtures/ebin"
      cp "$root"/_build/test/lib/spec_lint/ebin/Elixir.SpecLint.{ExperimentFixtures,Fixtures,OmissionFixtures}*.beam \
        "$raw/fixtures/ebin/"
      ebins=("$raw/fixtures/ebin")
      codepaths=("$root/_build/test/lib/spec_lint/ebin")
      ;;
    *)
      source_repo="$oss/$1"
      check_revision "$1" "$source_repo"
      local app subdir ebin_rel
      app="$1"
      subdir=""
      ebin_rel=""
      if [ -n "$manifest" ]; then
        app="$(jq -r --arg name "$1" '.[$name].app // $name' "$manifest")"
        subdir="$(jq -r --arg name "$1" '.[$name].project_subdir // empty' "$manifest")"
        ebin_rel="$(jq -r --arg name "$1" '.[$name].ebin // empty' "$manifest")"
      fi
      project_root="$source_repo/$subdir"
      if [ -z "$ebin_rel" ]; then ebin_rel="_build/test/lib/$app/ebin"; fi
      ebins=("$project_root/$ebin_rel")
      for d in "$project_root"/_build/test/lib/*/ebin; do codepaths+=("$d"); done
      ;;
  esac
}

for name in "${corpora[@]}"; do
  echo "== $name" >&2
  select_corpus "$name"
  for e in "${ebins[@]}"; do
    [ -d "$e" ] || { echo "missing corpus ebin: $e" >&2; exit 2; }
  done
  args=()
  for e in "${ebins[@]}"; do args+=(--ebin "$e"); done
  cp_args=()
  for c in ${codepaths[@]+"${codepaths[@]}"}; do cp_args+=(--code-path "$c"); done
  SPEC_LINT_RAW_DIR="$raw" ELIXIR_DIR="$elixir_dir" \
    bench/corpus/provenance.sh "$out/$name.provenance.json" "$name" "$source_repo" \
    "$project_root" "$root" "${ebins[@]}" ${codepaths[@]+"${codepaths[@]}"}

  if [ "$product_only" != 1 ]; then
    set +e
    MIX_ENV=test mix run bench/experiment.exs -- "${args[@]}" ${cp_args[@]+"${cp_args[@]}"} \
      --label "$name" --out "$raw/$name.json" 2>"$raw/$name.log"
    status=$?
    set -e
    if [ -s "$raw/$name.json" ]; then
      SPEC_LINT_ROOT="$root" SPEC_LINT_RAW_DIR="$raw" \
        bench/corpus/normalise_report.sh "$raw/$name.json" "$out/$name.json"
    fi
    if [ "$status" -ne 0 ] || [ ! -s "$raw/$name.json" ]; then
      cp "$raw/$name.log" "$out/$name.experiment.log"
      cat "$raw/$name.log" >&2
      echo "experiment failed for $name (exit $status); log retained at $out/$name.experiment.log" >&2
      exit 2
    fi
  fi

  if [ "$name" != fixtures ]; then
    set +e
    MIX_ENV=test mix run bench/run_on_ebin.exs -- "${args[@]}" ${cp_args[@]+"${cp_args[@]}"} \
      --root "$project_root" --ci --format json --output "$raw/$name.spec_lint.json" \
      ${product_args[@]+"${product_args[@]}"} >"$raw/$name.run.log" 2>&1
    status=$?
    set -e
    if [ ! -s "$raw/$name.spec_lint.json" ]; then
      cp "$raw/$name.run.log" "$out/$name.spec_lint.log"
      cat "$raw/$name.run.log" >&2
      exit 2
    fi
    echo "   mix spec_lint --ci equivalent exited $status" >&2
    SPEC_LINT_ROOT="$root" SPEC_LINT_RAW_DIR="$raw" \
      bench/corpus/normalise_report.sh "$raw/$name.spec_lint.json" "$out/$name.spec_lint.json"
    completion="$(jq -r '.completion.status' "$out/$name.spec_lint.json")"
    report_status="$(jq -r '.completion.exit_code' "$out/$name.spec_lint.json")"
    if [ "$status" -eq 2 ] || [ "$completion" != complete ] || [ "$report_status" -eq 2 ]; then
      cp "$raw/$name.run.log" "$out/$name.spec_lint.log"
      cat "$raw/$name.run.log" >&2
      echo "incomplete product run for $name (exit $status, completion $completion); log retained at $out/$name.spec_lint.log" >&2
      exit 2
    fi
    if [ "$status" -ne "$report_status" ]; then
      cp "$raw/$name.run.log" "$out/$name.spec_lint.log"
      echo "exit status/report mismatch for $name: $status vs $report_status" >&2
      exit 2
    fi
  fi
done
