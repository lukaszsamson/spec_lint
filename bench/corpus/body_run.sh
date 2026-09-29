#!/usr/bin/env bash
# Regenerates bench/corpus/reports/body/*.json, the body-backend experiment
# of EXPERIMENTS.md "Body backend experiment" (bench/body_experiment.exs).
#
#     ELIXIR_BODY=/path/to/elixir-body SPEC_LINT_OSS=/path/to/oss \
#       [SPEC_LINT_OSS_BODY=/path/to/oss-body] bench/corpus/body_run.sh
#
# ELIXIR_BODY is a build of the pinned revision c24c235 with only the
# Module.Types.warnings/7 hook applied (see the README in this directory).
# c24c235 is on the branch ls-mixed-into of the fork
# https://github.com/lukaszsamson/elixir (not upstream); the hook is the
# lib/elixir/lib/module/types.ex hunk of b88a257a3 (branch
# ls-typespec-tightening of the same fork), committed here as
# bench/corpus/warnings7.patch:
#
#     git clone https://github.com/lukaszsamson/elixir.git "$ELIXIR_BODY"
#     git -C "$ELIXIR_BODY" checkout --detach c24c235
#     git -C "$ELIXIR_BODY" apply "$PWD/bench/corpus/warnings7.patch"
#     make -C "$ELIXIR_BODY" compile
#
# SPEC_LINT_OSS holds the decimal, plug and ecto checkouts (bench/corpus/README.md).
# They are compiled with the patched build into SPEC_LINT_OSS_BODY (default: a
# temporary directory) with MIX_BUILD_PATH, so the checkouts' own _build is
# not touched. The fixtures are compiled with the patched elixirc.
#
# Reports are normalised (paths replaced by $ELIXIR_BODY, $OSS, $OSS_BODY,
# $SPEC_LINT and $TMP, keys sorted). They keep the wall-clock cost fields
# (`body_us`, `default_run_us`, `totals.cost`), so two runs differ there.
#
# Runs under bash 3.2 (the macOS system bash) and later: no associative
# arrays.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
body="${ELIXIR_BODY:?set ELIXIR_BODY to the patched Elixir build}"
oss="${SPEC_LINT_OSS:?set SPEC_LINT_OSS to the directory holding the corpus checkouts}"
out="${SPEC_LINT_BODY_OUT:-$root/bench/corpus/reports/body}"
raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT
oss_body="${SPEC_LINT_OSS_BODY:-$raw/oss-body}"
mkdir -p "$oss_body"
# Always compile into a new build path. Reusing an existing path can silently
# measure artifacts from an earlier source revision.
oss_body="$(mktemp -d "$oss_body/spec-lint-body.XXXXXX")"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

body_revision="$(git -C "$body" rev-parse HEAD)"
if [ "$body_revision" != c24c23538d521d25edd6a9a7a66fc5206caab70e ]; then
  echo "unexpected patched compiler revision: $body_revision" >&2
  exit 2
fi

"$body/bin/elixir" -e 'Code.ensure_loaded!(Module.Types)
  unless function_exported?(Module.Types, :warnings, 7), do: System.halt(3)' ||
  { echo "$body has no Module.Types.warnings/7" >&2; exit 2; }

cd "$root"
mkdir -p "$out"
MIX_ENV=test mix compile >/dev/null
spec_lint_ebin="$root/_build/test/lib/spec_lint/ebin"

run() {
  local name="$1"
  shift
  echo "== $name" >&2
  "$body/bin/elixir" -pa "$spec_lint_ebin" bench/body_experiment.exs -- "$@" \
    --label "$name" --out "$raw/$name.json" 2>"$raw/$name.log" ||
    { cat "$raw/$name.log" >&2; exit 1; }
  jq -S --arg oss_body "$oss_body" --arg oss "$oss" --arg body "$body" \
    --arg root "$root" --arg raw "$raw" '
    walk(if type == "string" then
      (split($oss_body) | join("$OSS_BODY") | split($oss) | join("$OSS") |
       split($body) | join("$ELIXIR_BODY") | split($root) | join("$SPEC_LINT") |
       split($raw) | join("$TMP"))
    else . end)' "$raw/$name.json" |
    jq -S -f bench/corpus/reduce_body_report.jq >"$raw/$name.reduced.json"
  case "$name" in
    # The full runs repeat the detail of the sampled runs; keep their totals,
    # omissions, class changes and one row per function.
    *_full) jq -S 'del(.functions)' "$raw/$name.reduced.json" >"$out/$name.json" ;;
    *) mv "$raw/$name.reduced.json" "$out/$name.json" ;;
  esac
  local source_repo project_root
  case "$name" in
    fixtures) source_repo="$root"; project_root="$root" ;;
    enum_keyword) source_repo="$body"; project_root="$body" ;;
    *) source_repo="$oss/${name%_full}"; project_root="$source_repo" ;;
  esac
  SPEC_LINT_ELIXIR_BIN="$body/bin/elixir" SPEC_LINT_COMPILER_REPO="$body" \
    SPEC_LINT_COMPILER_PATCH="$root/bench/corpus/warnings7.patch" \
    bench/corpus/provenance.sh "$out/$name.provenance.json" "$name" \
    "$source_repo" "$project_root" "$root" \
    "${provenance_ebins[@]}"
}

# Fixtures: the omission reproducers and the experiment fixtures, compiled
# with the patched compiler (SpecLint.Fixtures is only needed to compile them).
mkdir -p "$raw/fixtures_ebin"
"$body/bin/elixirc" -o "$raw/fixtures_ebin" test/support/fixtures.ex \
  test/support/omission_fixtures.ex test/support/experiment_fixtures.ex >/dev/null
provenance_ebins=("$raw/fixtures_ebin")
run fixtures --ebin "$raw/fixtures_ebin" \
  --prefix SpecLint.OmissionFixtures --prefix SpecLint.ExperimentFixtures

# Cost on two stdlib modules (DESIGN.md section 7, item 4).
provenance_ebins=("$body/lib/elixir/ebin")
run enum_keyword --ebin "$body/lib/elixir/ebin" --module Enum --module Keyword

# decimal, plug, ecto: the omission modules plus 30 random others (the whole
# candidate pool of decimal, 1, and of plug, 11, then 18 from ecto; seed
# 20260928), then every module of each library.
for lib in decimal plug ecto; do
  case "$lib" in
    decimal) pinned=92a28e6b9a103f2b52a22b3f772f7a2a34b7b1d5 ;;
    plug) pinned=73404f851852a00ffb2014be95d4598900fa77b8 ;;
    ecto) pinned=94d69279c517347ff0962b138f4ccd0556486ae2 ;;
  esac
  actual="$(git -C "$oss/$lib" rev-parse HEAD)"
  if [ "$actual" != "$pinned" ]; then
    echo "unexpected revision for $lib: $actual (expected $pinned)" >&2
    exit 2
  fi
  echo "== compiling $lib with the patched build into $oss_body/$lib" >&2
  (cd "$oss/$lib" && PATH="$body/bin:$PATH" MIX_ENV=test MIX_BUILD_PATH="$oss_body/$lib" \
    "$body/bin/mix" compile >"$raw/$lib.compile.log" 2>&1) ||
    { cat "$raw/$lib.compile.log" >&2; exit 2; }
done

# LIB:SAMPLE pairs: the number of random modules drawn from each library.
for pair in decimal:1 plug:11 ecto:18; do
  lib="${pair%%:*}"
  sample="${pair##*:}"
  cp_args=()
  for d in "$oss_body/$lib"/lib/*/ebin; do cp_args+=(--code-path "$d"); done
  ebin="$oss_body/$lib/lib/$lib/ebin"
  provenance_ebins=("$ebin")
  run "$lib" --ebin "$ebin" "${cp_args[@]}" --sample "$sample" --seed 20260928
  run "${lib}_full" --ebin "$ebin" "${cp_args[@]}"
done
