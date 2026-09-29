#!/usr/bin/env bash
# Compares two directories of normalised product reports (NAME.spec_lint.json)
# corpus by corpus and prints a JSON summary: completion, exit code, ledger,
# findings (whole records, and without their rendered details), gates and
# fingerprints, plus the list of top-level report keys that differ.
#
#     compare_replay.sh NEW_DIR BASE_DIR[:corpus,...] [BASE_DIR[:corpus,...] ...]
#
# Each BASE_DIR argument supplies the baseline for the corpora named after
# the colon (all corpora of NEW_DIR when none are named); later arguments
# override earlier ones. Runs under bash 3.2 and later.
#
# Milestone 1 (bench/corpus/reports/m1/summary.json), from reports/:
#     ../compare_replay.sh m1 phase4 expansion/clause_local/on:absinthe
set -euo pipefail
[ "$#" -ge 2 ] || { echo "usage: $0 NEW_DIR BASE_DIR[:corpus,...] ..." >&2; exit 2; }
new="$1"; shift
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

base_for() {
  local corpus="$1" found="" spec dir names
  for spec in "${bases[@]}"; do
    dir="${spec%%:*}"; names=""
    [ "$spec" != "$dir" ] && names="${spec#*:}"
    if [ -z "$names" ] || [[ ",$names," == *",$corpus,"* ]]; then found="$dir"; fi
  done
  echo "$found"
}

bases=("$@")
entries="[]"
for report in "$new"/*.spec_lint.json; do
  corpus="$(basename "$report" .spec_lint.json)"
  base_dir="$(base_for "$corpus")"
  base="$base_dir/$corpus.spec_lint.json"
  if [ ! -f "$base" ]; then
    entry="$(jq -n --arg c "$corpus" '{corpus: $c, baseline: null}')"
  else
    entry="$(jq -n --arg c "$corpus" --arg b "$base_dir" \
      --slurpfile n "$report" --slurpfile o "$base" '
      def gates(r): [r.findings[] | select(.gate) | {subject, rule, slice, clause, fingerprint}] | sort_by(.fingerprint);
      def fps(r): [r.findings[] | .fingerprint] | sort;
      def nodetails(r): [r.findings[] | del(.details)];
      $n[0] as $n | $o[0] as $o |
      {corpus: $c, baseline: $b,
       completion: $n.completion.status, previous_completion: $o.completion.status,
       exit_code: $n.completion.exit_code, previous_exit_code: $o.completion.exit_code,
       compared_slices: $n.ledger.slices.compared,
       unknown_obligations: ($n.ledger.obligations.unknown // null),
       findings: ($n.findings | length), previous_findings: ($o.findings | length),
       gates: (gates($n) | length), previous_gates: (gates($o) | length),
       added_gates: (gates($n) - gates($o)), removed_gates: (gates($o) - gates($n)),
       ledger_unchanged: ($n.ledger == $o.ledger),
       findings_unchanged: ($n.findings == $o.findings),
       findings_except_details_unchanged: (nodetails($n) == nodetails($o)),
       fingerprints_unchanged: (fps($n) == fps($o)),
       differing_report_keys: ([($n | keys[]), ($o | keys[])] | unique | map(select($n[.] != $o[.])))}')"
  fi
  entries="$(jq -n --argjson e "$entries" --argjson x "$entry" '$e + [$x]')"
done
jq -n --argjson e "$entries" '{schema: "spec_lint.m1_replay/1", corpora: $e,
  totals: {compared_slices: ([$e[].compared_slices // 0] | add),
           findings: ([$e[].findings // 0] | add), gates: ([$e[].gates // 0] | add),
           previous_gates: ([$e[].previous_gates // 0] | add)},
  all_unchanged: ([$e[] | .ledger_unchanged and .findings_unchanged and .fingerprints_unchanged
                   and .added_gates == [] and .removed_gates == []
                   and .exit_code == .previous_exit_code] | all)}'
