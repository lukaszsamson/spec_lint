#!/usr/bin/env bash
# Write reproducible corpus input identity alongside its reports.
#
# Machine-local path prefixes are replaced as in normalise_report.sh:
# SPEC_LINT_OSS -> $OSS, ELIXIR_DIR (default ~/elixir) -> $ELIXIR,
# SPEC_LINT_COMPILER_REPO -> $COMPILER, SPEC_LINT_RAW_DIR -> $TMP and the
# tool repository -> $SPEC_LINT, each in its given and its canonical
# (symlink-resolved) spelling. Identity is carried by the sha256 values,
# which never depend on these paths.
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: provenance.sh OUT.json NAME SOURCE_REPO PROJECT_ROOT TOOL_REPO [EBIN ...]" >&2
  exit 2
fi
dest="$1" name="$2" source_repo="$3" project_root="$4" tool_repo="$5"
shift 5

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
command -v shasum >/dev/null || { echo "shasum is required" >&2; exit 2; }

git_revision() { git -C "$1" rev-parse HEAD; }
git_dirty() { [ -n "$(git -C "$1" status --porcelain)" ]; }
hash_file() {
  if [ -f "$1" ]; then shasum -a 256 "$1" | awk '{print $1}'; else echo null; fi
}
hash_ebin() {
  # Batch files into a few shasum processes, then sort digest/path rows so
  # filesystem traversal and xargs batch boundaries do not affect identity.
  (cd "$1" && find . -type f -name '*.beam' -print0 |
    xargs -0 shasum -a 256 | LC_ALL=C sort) | shasum -a 256 | awk '{print $1}'
}
hash_tool_sources() {
  (cd "$1" && git ls-files -co --exclude-standard -- lib bench test/support mix.exs |
    LC_ALL=C sort -u | while IFS= read -r path; do
      case "$path" in
        lib/*|test/support/*|mix.exs|bench/*.exs|bench/*.sh|bench/*.jq|bench/*.patch) ;;
        *) continue ;;
      esac
      [ -f "$path" ] && shasum -a 256 "$path"
    done) | shasum -a 256 | awk '{print $1}'
}

source_revision="$(git_revision "$source_repo")"
tool_revision="$(git_revision "$tool_repo")"
source_dirty=false
tool_dirty=false
if git_dirty "$source_repo"; then source_dirty=true; fi
if git_dirty "$tool_repo"; then tool_dirty=true; fi
source_lock="$(hash_file "$project_root/mix.lock")"
tool_lock="$(hash_file "$tool_repo/mix.lock")"
tool_sources="$(hash_tool_sources "$tool_repo")"
manifest_hash="$(hash_file "${SPEC_LINT_CORPUS_MANIFEST:-/dev/null}")"
elixir_bin="${SPEC_LINT_ELIXIR_BIN:-elixir}"
compiler_beam="$("$elixir_bin" -e 'IO.puts(:code.which(Module.Types))')"
if [ ! -f "$compiler_beam" ]; then
  echo "cannot find loaded Module.Types BEAM: $compiler_beam" >&2
  exit 2
fi
compiler_beam_hash="$(hash_file "$compiler_beam")"
artifact_rows='[]'
for ebin in "$@"; do
  [ -d "$ebin" ] || { echo "missing ebin: $ebin" >&2; exit 2; }
  beam_count="$(find "$ebin" -type f -name '*.beam' | wc -l | tr -d ' ')"
  [ "$beam_count" -gt 0 ] || { echo "empty ebin: $ebin" >&2; exit 2; }
  artifact_rows="$(jq -cn --argjson previous "$artifact_rows" \
    --arg path "$ebin" --arg sha256 "$(hash_ebin "$ebin")" \
    --argjson beams "$beam_count" \
    '$previous + [{path: $path, beam_count: $beams, sha256: $sha256}]')"
done

compiler_rows='null'
if [ -n "${SPEC_LINT_COMPILER_REPO:-}" ]; then
  compiler_revision="$(git_revision "$SPEC_LINT_COMPILER_REPO")"
  compiler_dirty=false
  if git_dirty "$SPEC_LINT_COMPILER_REPO"; then compiler_dirty=true; fi
  patch_hash="$(hash_file "${SPEC_LINT_COMPILER_PATCH:-/dev/null}")"
  compiler_rows="$(jq -nS --arg revision "$compiler_revision" \
    --argjson dirty "$compiler_dirty" --arg patch "$patch_hash" \
    '{revision: $revision, dirty: $dirty,
      patch_sha256: (if $patch == "null" then null else $patch end)}')"
fi

canonical_path() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s\n' "$1"; fi
}

oss="${SPEC_LINT_OSS:-/dev/null}"
elixir_dir="${ELIXIR_DIR:-$HOME/elixir}"
compiler_repo="${SPEC_LINT_COMPILER_REPO:-/dev/null}"
raw="${SPEC_LINT_RAW_DIR:-/dev/null}"

mkdir -p "$(dirname "$dest")"
jq -nS --arg name "$name" --arg source_revision "$source_revision" \
  --arg tool_revision "$tool_revision" --argjson source_dirty "$source_dirty" \
  --argjson tool_dirty "$tool_dirty" --arg source_lock "$source_lock" \
  --arg tool_lock "$tool_lock" --argjson ebins "$artifact_rows" \
  --argjson compiler "$compiler_rows" \
  --arg tool_sources "$tool_sources" --arg compiler_beam "$compiler_beam" \
  --arg compiler_beam_hash "$compiler_beam_hash" --arg manifest_hash "$manifest_hash" \
  --arg elixir "$("$elixir_bin" --version | tail -1)" \
  '{schema: "spec_lint.corpus_provenance/1", corpus: $name,
    source: {revision: $source_revision, dirty: $source_dirty,
             lockfile_sha256: (if $source_lock == "null" then null else $source_lock end)},
    tool: {revision: $tool_revision, dirty: $tool_dirty,
           lockfile_sha256: (if $tool_lock == "null" then null else $tool_lock end),
           source_sha256: $tool_sources},
    toolchain: {elixir: $elixir, compiler: $compiler,
      loaded_module_types_beam: $compiler_beam,
      loaded_module_types_sha256: $compiler_beam_hash},
    corpus_manifest_sha256: (if $manifest_hash == "null" then null else $manifest_hash end),
    artifacts: $ebins}' |
  jq -S --arg oss_real "$(canonical_path "$oss")" --arg oss "$oss" \
    --arg elixir_real "$(canonical_path "$elixir_dir")" --arg elixir "$elixir_dir" \
    --arg compiler_real "$(canonical_path "$compiler_repo")" --arg compiler "$compiler_repo" \
    --arg raw_real "$(canonical_path "$raw")" --arg raw "$raw" \
    --arg root_real "$(canonical_path "$tool_repo")" --arg root "$tool_repo" '
    walk(if type == "string" then
      (split($oss_real) | join("$OSS") | split($oss) | join("$OSS") |
       split($compiler_real) | join("$COMPILER") | split($compiler) | join("$COMPILER") |
       split($elixir_real) | join("$ELIXIR") | split($elixir) | join("$ELIXIR") |
       split($raw_real) | join("$TMP") | split($raw) | join("$TMP") |
       split($root_real) | join("$SPEC_LINT") | split($root) | join("$SPEC_LINT"))
    else . end)' >"$dest"
