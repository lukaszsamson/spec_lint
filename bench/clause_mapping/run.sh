#!/usr/bin/env bash
# Runs recompute.exs over the fixtures and the fifteen corpora (read-only:
# BEAM files of the existing c24c235 builds are only read).
#
#   TOOL_EBIN=/path/to/spec_lint/ebin SPEC_LINT_OSS=... SPEC_LINT_EXPANSION=... \
#     OUT=/path/to/out bench/clause_mapping/run.sh [corpus ...]
#
# TOOL_EBIN is a build of SpecLint (only SpecLint.Beam and the compiler
# adapter are used); it must not be the build of the checkout another
# process is compiling. The qualified compiler c24c235 must be on PATH:
# recompute.exs exits 2 under any other one. ELIXIR_DIR (default
# $HOME/elixir) is that compiler's checkout, whose lib/*/ebin are the
# standard library corpus. The corpus builds are the c24c235 builds of
# bench/corpus (SPEC_LINT_OSS for the original six, SPEC_LINT_EXPANSION for
# the expansion eight). See README.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${TOOL_EBIN:?set TOOL_EBIN}"
oss="${SPEC_LINT_OSS:?set SPEC_LINT_OSS}"
exp="${SPEC_LINT_EXPANSION:?set SPEC_LINT_EXPANSION}"
elixir_dir="${ELIXIR_DIR:-$HOME/elixir}"
out="${OUT:?set OUT}"
mkdir -p "$out"

focus=(--focus Absinthe.Blueprint.Input.parse/1 --focus Ash.Page.page_opts/1
       --focus Oban.Registry.via/3)

run_corpus() {
  local name="$1" build="$2" app="$3"
  local args=(--label "$name" --out "$out/$name.json")
  if [ "$name" = stdlib ]; then
    for a in elixir eex ex_unit iex logger mix; do args+=(--ebin "$elixir_dir/lib/$a/ebin"); done
  else
    args+=(--ebin "$build/lib/$app/ebin")
    for d in "$build"/lib/*/ebin; do
      [ "$d" = "$build/lib/$app/ebin" ] || args+=(--code-path "$d")
    done
  fi
  echo "== $name" >&2
  elixir -pa "$tool" "$here/recompute.exs" corpus "${args[@]}" "${focus[@]}" \
    >"$out/$name.summary.json" 2>"$out/$name.log"
}

corpora=("$@")
if [ ${#corpora[@]} -eq 0 ]; then
  corpora=(fixtures stdlib jason decimal nimble_options mime plug ecto req broadway oban
           phoenix_live_view ash nx absinthe tesla)
fi

for c in "${corpora[@]}"; do
  case "$c" in
    fixtures) elixir -pa "$tool" "$here/recompute.exs" fixtures "$out/fixtures.json" \
                >"$out/fixtures.txt" 2>"$out/fixtures.log" ;;
    stdlib) run_corpus stdlib "" "" ;;
    jason|decimal|nimble_options|mime|plug|ecto) run_corpus "$c" "$oss/$c/_build/test" "$c" ;;
    nx) run_corpus nx "$exp/nx/nx/_build/test" nx ;;
    *) run_corpus "$c" "$exp/$c/_build/test" "$c" ;;
  esac
done
