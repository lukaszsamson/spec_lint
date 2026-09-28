#!/usr/bin/env bash
# Regenerates bench/corpus/reports/*.json (see bench/corpus/README.md).
#
#     SPEC_LINT_OSS=/path/to/oss [ELIXIR_DIR=~/elixir] bench/corpus/run.sh [corpus ...]
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
# Both are normalised (absolute paths replaced by $OSS, $ELIXIR, $SPEC_LINT and
# $TMP, keys sorted, the wall-clock totals.runtime_ms removed) so a diff
# between two runs shows only real changes. A file over 2 MB is stored in reduced form: totals,
# class counts and every function that is neither `none` nor `unknown`.
#
# Runs under bash 3.2 (the macOS system bash) and later: no associative
# arrays, and empty arrays are expanded with ${a[@]+"${a[@]}"} (set -u).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
oss="${SPEC_LINT_OSS:?set SPEC_LINT_OSS to the directory holding the corpus checkouts}"
elixir_dir="${ELIXIR_DIR:-$HOME/elixir}"
out="$root/bench/corpus/reports"
raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT
limit=2000000

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# revision NAME -> the pinned revision of a corpus checkout.
revision() {
  case "$1" in
    jason) echo 4ede42858eb19f80ec9e863aab52df466eab8608 ;;
    decimal) echo 92a28e6b9a103f2b52a22b3f772f7a2a34b7b1d5 ;;
    nimble_options) echo 825c05837f236c612c6ac2855735ec6cf7f2be69 ;;
    mime) echo 23dcc1593ccc49648e33b9ed3c03bd516795f6d9 ;;
    plug) echo 73404f851852a00ffb2014be95d4598900fa77b8 ;;
    ecto) echo 94d69279c517347ff0962b138f4ccd0556486ae2 ;;
    *) echo "unknown corpus: $1" >&2; exit 2 ;;
  esac
}

if [ $# -gt 0 ]; then
  corpora=("$@")
else
  corpora=(stdlib jason decimal nimble_options mime plug ecto fixtures)
fi

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
      for app in elixir eex ex_unit iex logger mix; do
        ebins+=("$elixir_dir/lib/$app/ebin")
      done
      ;;
    fixtures)
      # Only the fixture modules, staged as an app called "fixtures".
      project_root="$root"
      mkdir -p "$raw/fixtures/ebin"
      cp "$root"/_build/test/lib/spec_lint/ebin/Elixir.SpecLint.{ExperimentFixtures,Fixtures,OmissionFixtures}*.beam \
        "$raw/fixtures/ebin/"
      ebins=("$raw/fixtures/ebin")
      codepaths=("$root/_build/test/lib/spec_lint/ebin")
      ;;
    *)
      project_root="$oss/$1"
      local rev pinned
      pinned="$(revision "$1")"
      rev="$(git -C "$oss/$1" rev-parse HEAD)"
      if [ "$rev" != "$pinned" ]; then
        echo "warning: $1 is at $rev, expected $pinned" >&2
      fi
      ebins=("$oss/$1/_build/test/lib/$1/ebin")
      for d in "$oss/$1"/_build/test/lib/*/ebin; do codepaths+=("$d"); done
      ;;
  esac
}

# normalise IN OUT: replace machine paths, sort keys, reduce when too big.
normalise() {
  local in="$1" dest="$2" tmp="$raw/normalised.json"
  sed -e "s#$oss#\$OSS#g" -e "s#$elixir_dir#\$ELIXIR#g" -e "s#$root#\$SPEC_LINT#g" -e "s#$raw#\$TMP#g" "$in" | jq -S "del(.totals.runtime_ms)" >"$tmp"
  if [ "$(wc -c <"$tmp")" -gt "$limit" ] && jq -e '.functions and .totals' "$tmp" >/dev/null; then
    jq -S '{label: .label, ebins: .ebins, code_paths: .code_paths, adapter: .adapter,
            otp_release: .otp_release, checker_version: .checker_version, totals: .totals,
            reduced: "totals, class counts and every function that is neither none nor unknown; the rest is dropped to stay under 2 MB",
            functions: [.functions[] | select(.class != "none" and .class != "unknown")]}' \
      "$tmp" >"$dest"
  elif [ "$(wc -c <"$tmp")" -gt "$limit" ]; then
    jq -S '{adapter, checker_version, reduced: "summary only; findings dropped to stay under 2 MB",
            summary, coverage, exit_status}' "$tmp" >"$dest"
  else
    mv "$tmp" "$dest"
  fi
}

for name in "${corpora[@]}"; do
  echo "== $name" >&2
  select_corpus "$name"
  args=()
  for e in "${ebins[@]}"; do args+=(--ebin "$e"); done
  cp_args=()
  for c in ${codepaths[@]+"${codepaths[@]}"}; do cp_args+=(--code-path "$c"); done

  MIX_ENV=test mix run bench/experiment.exs -- "${args[@]}" ${cp_args[@]+"${cp_args[@]}"} \
    --label "$name" --out "$raw/$name.json" 2>"$raw/$name.log" || { cat "$raw/$name.log" >&2; exit 1; }
  normalise "$raw/$name.json" "$out/$name.json"

  if [ "$name" != fixtures ]; then
    set +e
    MIX_ENV=test mix run bench/run_on_ebin.exs -- "${args[@]}" ${cp_args[@]+"${cp_args[@]}"} \
      --root "$project_root" --ci --format json --output "$raw/$name.spec_lint.json" \
      >"$raw/$name.run.log" 2>&1
    status=$?
    set -e
    [ -s "$raw/$name.spec_lint.json" ] || { cat "$raw/$name.run.log" >&2; exit 1; }
    echo "   mix spec_lint --ci equivalent exited $status" >&2
    normalise "$raw/$name.spec_lint.json" "$out/$name.spec_lint.json"
  fi
done
