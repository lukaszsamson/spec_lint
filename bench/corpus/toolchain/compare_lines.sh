#!/usr/bin/env bash
# Compares the product reports (NAME.spec_lint.json) of two compiler lines
# corpus by corpus, for the Milestone 3 comparison of Elixir 1.20.4 with
# 1.21. Unlike compare_replay.sh, which expects identical reports, it
# summarises what may legitimately differ between lines and lists every
# difference: coverage (slices found, compared, exact, approximate,
# unsupported, unavailable), obligations and unknown reasons, loss kinds,
# findings by rule and evidence, gates, fingerprints, and the ledger
# entries whose class, obligation, translation or unknown reason differ.
#
#     compare_lines.sh NEW_DIR BASE_DIR > summary.json
#
# Runs under bash 3.2 and later; needs jq.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 NEW_DIR BASE_DIR" >&2; exit 2; }
new="$1"; base="$2"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

entries="[]"
for report in "$new"/*.spec_lint.json; do
  corpus="$(basename "$report" .spec_lint.json)"
  other="$base/$corpus.spec_lint.json"
  [ -f "$other" ] || { echo "no baseline report for $corpus in $base" >&2; exit 2; }
  entry="$(jq -n --arg c "$corpus" --slurpfile n "$report" --slurpfile o "$other" '
    def coverage(r): r.ledger.slices | {found, compared, exact, approximate, unsupported, unavailable};
    def count_by(xs; f): xs | group_by(f) | map({key: (.[0] | f | tostring), value: length}) | from_entries;
    def gates(r): [r.findings[] | select(.gate) | {subject, rule, slice, clause}] | sort;
    def keyed(r): r.ledger.entries | map({key: "\(.mfa)#\(.slice)", value: {class, obligation, translation, unknown_reason, status}}) | from_entries;
    $n[0] as $n | $o[0] as $o |
    (keyed($n)) as $kn | (keyed($o)) as $ko |
    ([$kn | keys[]] + [$ko | keys[]] | unique) as $keys |
    ([$n.findings[] | .fingerprint]) as $fn | ([$o.findings[] | .fingerprint]) as $fo |
    {corpus: $c,
     adapters: [$n.adapter, $o.adapter],
     exit_codes: [$n.completion.exit_code, $o.completion.exit_code],
     completion: [$n.completion.status, $o.completion.status],
     coverage: [coverage($n), coverage($o)],
     coverage_equal: (coverage($n) == coverage($o)),
     obligations: [$n.ledger.obligations, $o.ledger.obligations],
     obligations_equal: ($n.ledger.obligations == $o.ledger.obligations),
     unknown_reasons: [$n.ledger.obligations_unknown_by_reason, $o.ledger.obligations_unknown_by_reason],
     unknown_reasons_equal: ($n.ledger.obligations_unknown_by_reason == $o.ledger.obligations_unknown_by_reason),
     loss_kinds_equal: ($n.ledger.slices.loss_kinds == $o.ledger.slices.loss_kinds),
     loss_kinds: (if $n.ledger.slices.loss_kinds == $o.ledger.slices.loss_kinds then null
                  else [$n.ledger.slices.loss_kinds, $o.ledger.slices.loss_kinds] end),
     findings: [($n.findings | length), ($o.findings | length)],
     findings_by_rule: [count_by($n.findings; .rule), count_by($o.findings; .rule)],
     findings_by_evidence: [count_by($n.findings; .evidence), count_by($o.findings; .evidence)],
     gates: [(gates($n) | length), (gates($o) | length)],
     gates_only_new: (gates($n) - gates($o)), gates_only_base: (gates($o) - gates($n)),
     findings_only_new: ([$n.findings[] | {subject, rule, slice, clause, evidence, gate}] - [$o.findings[] | {subject, rule, slice, clause, evidence, gate}]),
     findings_only_base: ([$o.findings[] | {subject, rule, slice, clause, evidence, gate}] - [$n.findings[] | {subject, rule, slice, clause, evidence, gate}]),
     fingerprints_shared: ([$fn[] | select(. as $f | $fo | index($f))] | length),
     entries_differing: [$keys[] | select($kn[.] != $ko[.]) | {entry: ., new: $kn[.], base: $ko[.]}]}')"
  entries="$(jq -n --argjson e "$entries" --argjson x "$entry" '$e + [$x]')"
done
jq -n --argjson e "$entries" '{schema: "spec_lint.line_comparison/1", corpora: $e,
  totals: {slices_compared: [([$e[].coverage[0].compared] | add), ([$e[].coverage[1].compared] | add)],
           findings: [([$e[].findings[0]] | add), ([$e[].findings[1]] | add)],
           gates: [([$e[].gates[0]] | add), ([$e[].gates[1]] | add)],
           unknown_obligations: [([$e[].obligations[0].unknown // 0] | add), ([$e[].obligations[1].unknown // 0] | add)],
           entries_differing: ([$e[].entries_differing | length] | add)}}'
