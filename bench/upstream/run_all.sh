#!/usr/bin/env bash
# Runs every reproducer against one Elixir build and prints one verdict per
# item. Nothing here needs SpecLint, Mix or the network.
#
#     bench/upstream/run_all.sh [ELIXIR_BIN [LABEL]]
#
# ELIXIR_BIN  the `elixir` executable to test (default: `elixir` on PATH);
#             for a version manager use ASDF_ELIXIR_VERSION=... before the
#             command instead.
# LABEL       name of the results directory under bench/upstream/results/
#             (default: revision reported by the build). The full output of
#             each reproducer is saved there as ITEM.txt.
#
# Exit status is 0 when every reproducer printed a verdict, 1 otherwise.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_bin="${1:-elixir}"
items="helper_insensitivity enum_map_result list_tl for_into_narrowing fun_printing map_top_printing printer_load_per_map subpatterns_leak checker_chunk_api"

revision="$("$elixir_bin" -e 'IO.write(System.build_info()[:revision])' 2>/dev/null)"
version="$("$elixir_bin" -e 'IO.write(System.version())' 2>/dev/null)"
if [ -z "$version" ]; then
  echo "cannot run $elixir_bin" >&2
  exit 1
fi
label="${2:-${version}-${revision}}"
out="$here/results/$label"
mkdir -p "$out"

echo "Elixir $version ($revision), results in results/$label/"
status=0
for item in $items; do
  "$elixir_bin" "$here/$item/repro.exs" >"$out/$item.txt" 2>&1
  rc=$?
  verdict="$(grep '^VERDICT: ' "$out/$item.txt" | tail -1 | sed 's/^VERDICT: //')"
  if [ "$rc" -ne 0 ] || [ -z "$verdict" ]; then
    verdict="ERROR (exit $rc, see $item.txt)"
    status=1
  fi
  printf '  %-22s %s\n' "$item" "$verdict"
done
exit $status
