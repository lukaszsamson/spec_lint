#!/usr/bin/env bash
# Normalise a corpus report. Large reports retain the full JSON as .json.gz
# and put a schema-checked summary at the requested .json path.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: normalise_report.sh IN.json OUT.json" >&2
  exit 2
fi

source_file="$1"
dest="$2"
limit="${SPEC_LINT_REPORT_LIMIT:-2000000}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
case "$limit" in *[!0-9]*|'') echo "invalid report limit: $limit" >&2; exit 2 ;; esac

oss="${SPEC_LINT_OSS:-/dev/null}"
elixir_dir="${ELIXIR_DIR:-$HOME/elixir}"
root="${SPEC_LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
raw="${SPEC_LINT_RAW_DIR:-/dev/null}"

canonical_path() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s\n' "$1"; fi
}

jq -S --arg oss_real "$(canonical_path "$oss")" \
  --arg elixir_real "$(canonical_path "$elixir_dir")" \
  --arg root_real "$(canonical_path "$root")" --arg raw_real "$(canonical_path "$raw")" \
  --arg oss "$oss" --arg elixir "$elixir_dir" --arg root "$root" \
  --arg raw "$raw" '
  walk(if type == "string" then
    (split($oss_real) | join("$OSS") | split($oss) | join("$OSS") |
     split($elixir_real) | join("$ELIXIR") | split($elixir) | join("$ELIXIR") |
     split($raw_real) | join("$TMP") | split($raw) | join("$TMP") |
     split($root_real) | join("$SPEC_LINT") | split($root) | join("$SPEC_LINT"))
  else . end) | del(.totals.runtime_ms)' "$source_file" >"$tmp/full.json"

if jq -e '(.functions | type == "array") and (.totals | type == "object") and
    (.adapter | type == "string")' "$tmp/full.json" >/dev/null; then
  kind=experiment
elif jq -e '(.findings | type == "array") and (.ledger | type == "object") and
    (.completion | type == "object") and (.completion.status | type == "string") and
    (.completion.exit_code | type == "number")' "$tmp/full.json" >/dev/null; then
  kind=product
else
  echo "unrecognised or incomplete report schema: $source_file" >&2
  exit 2
fi

mkdir -p "$(dirname "$dest")"
if [ "$(wc -c <"$tmp/full.json")" -le "$limit" ]; then
  mv "$tmp/full.json" "$dest"
  rm -f "$dest.gz"
  exit 0
fi

if [ "$kind" = experiment ]; then
  jq -S '{label: .label, ebins, code_paths, adapter, otp_release, checker_version,
          totals, fixtures, reduced: "full normalized report in adjacent .json.gz",
          functions: [.functions[] | select(.class != "none" and .class != "unknown")]}' \
    "$tmp/full.json" >"$tmp/summary.json"
  jq -e '(.totals | type == "object") and (.functions | type == "array")' \
    "$tmp/summary.json" >/dev/null
else
  jq -S '{schema, schema_version, tool, adapter, checker_version, project, scope,
          completion, ledger, baseline,
          finding_count: (.findings | length), findings,
          reduced: "full normalized report in adjacent .json.gz"}' \
    "$tmp/full.json" >"$tmp/summary.json"
  jq -e '(.completion.status | type == "string") and
    (.ledger | type == "object") and (.findings | type == "array")' \
    "$tmp/summary.json" >/dev/null
fi

gzip -n -c "$tmp/full.json" >"$tmp/full.json.gz"
mv "$tmp/full.json.gz" "$dest.gz"
mv "$tmp/summary.json" "$dest"
