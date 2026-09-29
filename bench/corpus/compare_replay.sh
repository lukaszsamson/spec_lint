#!/usr/bin/env bash
# Compares two directories of normalised product reports (NAME.spec_lint.json)
# corpus by corpus and prints a JSON summary: completion, exit code, ledger,
# findings (whole records, and without their rendered details), gates and
# fingerprints, plus the list of top-level report keys that differ.
# all_unchanged requires equality of every report key except beams: their
# artifact hashes contain build paths (provenance.sh). Adapter, config,
# scope, coverage and completion differences are never ignored.
#
#     compare_replay.sh NEW_DIR BASE_DIR[:corpus,...] [BASE_DIR[:corpus,...] ...]
#
# Each BASE_DIR argument supplies the baseline for the corpora named after
# the colon (all corpora of NEW_DIR when none are named); later arguments
# override earlier ones. Runs under bash 3.2 and later.
#
# A new report that is missing, unreadable (truncated, not JSON) or not
# `complete` is an incomplete result, never a comparison: its entry has
# `status` "missing", "unreadable" or its completion status, `all_unchanged`
# is false, the corpus is listed in `incomplete`, and the script exits 2
# after printing the summary. The corpora expected in NEW_DIR are those with
# a report or a provenance file there (run.sh writes the provenance first;
# not `fixtures`, which has no product report),
# every corpus of a BASE_DIR given without a list, the corpora named in the
# lists, and SPEC_LINT_EXPECTED_CORPORA (whitespace-separated), if set.
#
# Milestone 1 (bench/corpus/reports/m1/summary.json), from reports/:
#     ../compare_replay.sh m1 phase4 expansion/clause_local/on:absinthe
#
# A NEW_DIR or BASE_DIR that does not exist, or an empty expected set (for
# example a runner killed during its first compile, and a mistyped base),
# is an error (exit 2), never a vacuous `all_unchanged`.
set -euo pipefail
[ "$#" -ge 2 ] || { echo "usage: $0 NEW_DIR BASE_DIR[:corpus,...] ..." >&2; exit 2; }
new="$1"; shift
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
[ -d "$new" ] || { echo "no such report directory: $new" >&2; exit 2; }
for spec in "$@"; do
  [ -d "${spec%%:*}" ] || { echo "no such report directory: ${spec%%:*}" >&2; exit 2; }
done

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

# Expected corpora, one per line, sorted and unique.
expected_corpora() {
  local f spec dir names
  for f in "$new"/*.spec_lint.json "$new"/*.provenance.json; do
    [ -e "$f" ] || continue
    f="$(basename "$f")"
    # The fixtures corpus has an experiment report only (run.sh).
    [ "${f%%.*}" = fixtures ] || echo "${f%%.*}"
  done
  for spec in "${bases[@]}"; do
    dir="${spec%%:*}"; names=""
    [ "$spec" != "$dir" ] && names="${spec#*:}"
    if [ -n "$names" ]; then
      echo "$names" | tr ',' '\n'
    else
      for f in "$dir"/*.spec_lint.json; do
        [ -e "$f" ] && basename "$f" .spec_lint.json
      done
    fi
  done
  for f in ${SPEC_LINT_EXPECTED_CORPORA:-}; do echo "$f"; done
}

readable() {
  jq -e 'type == "object" and (.completion.status | type == "string") and
    (.completion.exit_code | type == "number") and (.ledger | type == "object") and
    (.findings | type == "array")' "$1" >/dev/null 2>&1
}

corpora="$(expected_corpora | grep -v '^$' | LC_ALL=C sort -u || true)"
[ -n "$corpora" ] || { echo "no corpora to compare: $new and the base directories hold no reports" >&2; exit 2; }

entries="[]"
for corpus in $corpora; do
  report="$new/$corpus.spec_lint.json"
  base_dir="$(base_for "$corpus")"
  base="$base_dir/$corpus.spec_lint.json"
  if [ ! -f "$report" ]; then
    entry="$(jq -n --arg c "$corpus" --arg b "$base_dir" \
      '{corpus: $c, baseline: (if $b == "" then null else $b end), status: "missing"}')"
  elif ! readable "$report"; then
    entry="$(jq -n --arg c "$corpus" --arg b "$base_dir" \
      '{corpus: $c, baseline: (if $b == "" then null else $b end), status: "unreadable"}')"
  elif [ ! -f "$base" ] || ! readable "$base"; then
    entry="$(jq -n --arg c "$corpus" --slurpfile n "$report" \
      '{corpus: $c, baseline: null, status: $n[0].completion.status,
        completion: $n[0].completion.status, exit_code: $n[0].completion.exit_code}')"
  else
    entry="$(jq -n --arg c "$corpus" --arg b "$base_dir" \
      --slurpfile n "$report" --slurpfile o "$base" '
      def comparable(r): r | del(.beams);
      def gates(r): [r.findings[] | select(.gate) | {subject, rule, slice, clause, fingerprint}] | sort_by(.fingerprint);
      def fps(r): [r.findings[] | .fingerprint] | sort;
      def nodetails(r): [r.findings[] | del(.details)];
      $n[0] as $n | $o[0] as $o |
      {corpus: $c, baseline: $b, status: $n.completion.status,
       completion: $n.completion.status, previous_completion: $o.completion.status,
       exit_code: $n.completion.exit_code, previous_exit_code: $o.completion.exit_code,
       compared_slices: $n.ledger.slices.compared,
       unknown_obligations: ($n.ledger.obligations.unknown // null),
       findings: ($n.findings | length), previous_findings: ($o.findings | length),
       gates: (gates($n) | length), previous_gates: (gates($o) | length),
       added_gates: (gates($n) - gates($o)), removed_gates: (gates($o) - gates($n)),
       report_unchanged: (comparable($n) == comparable($o)),
       allowed_differing_report_keys: ["beams"],
       ledger_unchanged: ($n.ledger == $o.ledger),
       findings_unchanged: ($n.findings == $o.findings),
       findings_except_details_unchanged: (nodetails($n) == nodetails($o)),
       fingerprints_unchanged: (fps($n) == fps($o)),
       differing_report_keys: ([($n | keys[]), ($o | keys[])] | unique | map(. as $key | select($n[$key] != $o[$key] or (($n | has($key)) != ($o | has($key))))))}')"
  fi
  entries="$(jq -n --argjson e "$entries" --argjson x "$entry" '$e + [$x]')"
done
jq -n --argjson e "$entries" '{schema: "spec_lint.m1_replay/1", corpora: $e,
  totals: {compared_slices: ([$e[].compared_slices // 0] | add),
           findings: ([$e[].findings // 0] | add), gates: ([$e[].gates // 0] | add),
           previous_gates: ([$e[].previous_gates // 0] | add)},
  incomplete: [$e[] | select(.status != "complete") | .corpus],
  all_unchanged: (($e | length) > 0 and
                  ([$e[] | .status == "complete" and .baseline != null
                    and .previous_completion == "complete" and .report_unchanged
                    and .ledger_unchanged and .findings_unchanged and .fingerprints_unchanged
                    and .added_gates == [] and .removed_gates == []
                    and .exit_code == .previous_exit_code] | all))}'
if jq -e 'any(.[]; .status != "complete")' <<<"$entries" >/dev/null; then
  echo "incomplete results: $(jq -r '[.[] | select(.status != "complete") |
    "\(.corpus) (\(.status))"] | join(", ")' <<<"$entries")" >&2
  exit 2
fi
