#!/usr/bin/env bash
# Lists every gated finding of the product reports in NEW_DIR with its
# status against BASE_DIR, for the refutation phase of a release campaign
# (Milestone 5: "re-run all known gates and independently attempt to refute
# every new or changed gate").
#
#     gate_diff.sh NEW_DIR BASE_DIR > gates.json
#
# A gate is identified by corpus, subject (the MFA), rule, evidence, slice
# and stored clause. Its status is `new` when BASE_DIR has no gated finding
# with that identity, `changed` when it has one whose fingerprint or whose
# record other than the rendered details and the baseline decision differs,
# and `unchanged` otherwise. Gates of BASE_DIR that NEW_DIR lacks are
# listed with status `removed`. `changes` names the finding keys that
# differ from the previous gate (for example `data` when only the
# diagnostic data grew, `fingerprint` when the identity moved). The adapter
# is the report's. A corpus
# report that is missing or not complete in NEW_DIR fails the script
# (exit 2): compare_replay.sh first. Runs under bash 3.2 and later.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 NEW_DIR BASE_DIR" >&2; exit 2; }
new="$1" base="$2"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

rows="[]"
for report in "$new"/*.spec_lint.json; do
  [ -e "$report" ] || continue
  corpus="$(basename "$report" .spec_lint.json)"
  jq -e '.completion.status == "complete"' "$report" >/dev/null 2>&1 ||
    { echo "report not complete: $report" >&2; exit 2; }
  previous="$base/$corpus.spec_lint.json"
  [ -f "$previous" ] || previous=/dev/null
  rows="$(jq -n --argjson rows "$rows" --arg corpus "$corpus" \
    --slurpfile n "$report" --slurpfile o "$previous" '
    def key: {subject, rule, evidence, slice, clause};
    def body: del(.details, .baseline);
    def gates(r): [r.findings[]? | select(.gate)];
    ($o[0] // {findings: []}) as $o |
    gates($n[0]) as $ng | gates($o) as $og |
    $rows +
    [$ng[] | . as $g | ([$og[] | select(key == ($g | key))] | first) as $p |
      {corpus: $corpus, adapter: $n[0].adapter, subject, rule, evidence, slice, clause,
       line, fingerprint,
       previous_fingerprint: ($p.fingerprint // null),
       changes: (if $p == null then null
                 else [(($p | body | keys) + ($g | body | keys)) | unique[] as $k
                       | select(($p | body)[$k] != ($g | body)[$k]) | $k] end),
       status: (if $p == null then "new"
                elif ($p.fingerprint != .fingerprint) or ($p | body) != body then "changed"
                else "unchanged" end)}] +
    [$og[] | . as $p | select([$ng[] | key] | index($p | key) | not) |
      {corpus: $corpus, adapter: ($o.adapter // null), subject, rule, evidence, slice, clause,
       line, fingerprint: null, previous_fingerprint: .fingerprint, status: "removed"}]')"
done
jq -n --argjson rows "$rows" --arg new "$new" --arg base "$base" '
  {schema: "spec_lint.gate_diff/1", reports: $new, previous: $base,
   counts: ($rows | group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
   gates: $rows}'
