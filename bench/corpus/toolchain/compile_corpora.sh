#!/usr/bin/env bash
# Compiles corpus checkouts with a given Elixir build into separate build
# paths, leaving the checkouts' own _build untouched.
#
#     SPEC_LINT_OSS=DIR SPEC_LINT_CORPUS_BUILD=DIR ELIXIR_DIR=DIR \
#       [SPEC_LINT_CORPUS_MANIFEST=FILE] compile_corpora.sh NAME ...
#
# For each NAME the project is $SPEC_LINT_OSS/NAME (plus the manifest's
# project_subdir), compiled with
#
#     MIX_ENV=test MIX_BUILD_PATH=$SPEC_LINT_CORPUS_BUILD/NAME \
#       PATH=$ELIXIR_DIR/bin:$PATH mix compile
#
# so its ebins are $SPEC_LINT_CORPUS_BUILD/NAME/lib/*/ebin, the layout
# run.sh reads when SPEC_LINT_CORPUS_BUILD is set. Dependencies must already
# be fetched (mix deps.get under the qualified toolchain). The checkout must
# be clean before and after (git status --porcelain), so compiling cannot
# change the sources. The log is NAME.compile.log in the build directory.
# Runs under bash 3.2 and later.
set -euo pipefail

oss="${SPEC_LINT_OSS:?set SPEC_LINT_OSS to the directory holding the corpus checkouts}"
build="${SPEC_LINT_CORPUS_BUILD:?set SPEC_LINT_CORPUS_BUILD to the output build root}"
elixir_dir="${ELIXIR_DIR:?set ELIXIR_DIR to the Elixir build to compile with}"
manifest="${SPEC_LINT_CORPUS_MANIFEST:-}"
[ "$#" -gt 0 ] || { echo "usage: $0 NAME ..." >&2; exit 2; }
[ -x "$elixir_dir/bin/mix" ] || { echo "no mix in $elixir_dir/bin" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

mkdir -p "$build"
for name in "$@"; do
  subdir=""
  if [ -n "$manifest" ]; then
    subdir="$(jq -r --arg name "$name" '.[$name].project_subdir // empty' "$manifest")"
  fi
  repo="$oss/$name"
  project="$repo/$subdir"
  [ -f "$project/mix.exs" ] || { echo "no mix project at $project" >&2; exit 2; }
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "$name: checkout is not clean before compiling" >&2
    exit 2
  fi
  echo "== $name ($(git -C "$repo" rev-parse HEAD))" >&2
  log="$build/$name.compile.log"
  if ! (cd "$project" && MIX_ENV=test MIX_BUILD_PATH="$build/$name" \
      PATH="$elixir_dir/bin:$PATH" mix compile) >"$log" 2>&1; then
    tail -20 "$log" >&2
    echo "$name: compile failed; log at $log" >&2
    exit 2
  fi
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "$name: compiling changed the checkout" >&2
    git -C "$repo" status --porcelain >&2
    exit 2
  fi
done
