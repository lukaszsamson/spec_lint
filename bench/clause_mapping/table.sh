#!/usr/bin/env bash
# Prints the per-corpus tables of README.md (the report) from OUT/*.summary.json.
#   bench/clause_mapping/table.sh OUT [variant ...]
set -euo pipefail
out="$1"; shift
variants=("$@")
[ ${#variants[@]} -gt 0 ] || variants=(robust_a1 robust_inv strict_a1)
corpora=(stdlib jason decimal nimble_options mime plug ecto req broadway oban
         phoenix_live_view ash nx absinthe tesla)
echo "Structural classes (I1/I2 and the handler shape only; no type is recomputed): trivial single clause, identity (as many stored as source clauses), {:super, ...} clause. Replay-checked: structural functions whose signature the replay reproduced, and how many of them the replay's own mapping agrees with."
echo
echo "| Corpus | Functions | Structural functions | Stored clauses | Structural stored clauses | Replay reproduced | Structural replay-checked: agree / wrong | Heads: fresh = compiler / differs |"
echo "| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |"
for c in "${corpora[@]}"; do
  f="$out/$c.summary.json"
  [ -s "$f" ] || { echo "| $c | missing |"; continue; }
  jq -r --arg c "$c" '
    .summary as $s |
    def pct(a; b): if b == 0 then "-" else ((a * 1000 / b | round) / 10 | tostring) + "%" end;
    ($s.functions_with_infer_signature) as $t |
    ($t - $s.nontrivial_functions) as $sf |
    ($s.stored_clauses - $s.nontrivial_stored_clauses) as $sc |
    (($s.replay[":term_equal"] // 0) + ($s.replay[":semantic_equal"] // 0)) as $rr |
    "| \($c) | \($t) | \($sf) (\(pct($sf; $t))) | \($s.stored_clauses) | \($sc) (\(pct($sc; $s.stored_clauses))) | \($rr) (\(pct($rr; $t))) | \($s.structural.agree) / \($s.structural.wrong) | \($s.heads_lo_equal["true"] // 0) / \($s.heads_lo_equal["false"] // 0) |"
  ' "$f"
done

for v in "${variants[@]}"; do
  echo
  echo "Variant \`$v\` (functions with an inferred signature; exact / ambiguous / unsupported; stored clauses exact; non-trivial functions exact / ambiguous / unsupported). Exact claims of a typed variant are unverified (README.md, E1-E3, R1-R2)."
  echo
  echo "| Corpus | Functions | Exact | Ambiguous | Unsupported | Stored clauses exact | Non-trivial | NT exact | NT ambiguous | NT unsupported | Replay-checked exact wrong / ambiguous unsound / no solution |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"
  for c in "${corpora[@]}"; do
    f="$out/$c.summary.json"
    [ -s "$f" ] || { echo "| $c | missing |"; continue; }
    jq -r --arg c "$c" --arg v "$v" '
      .summary as $s | $s.variants[$v] as $x |
      ($x.by_class) as $b |
      def n(k): ($b[k] // 0);
      (n(":trivial_single") + n(":identity") + n(":super_derived") + n(":solved") + n(":solved_multi")) as $ex |
      (n(":ambiguous") + n(":budget")) as $am |
      (n(":unsupported") + n(":no_solution") + n(":invariant_violation")) as $un |
      ($s.functions_with_infer_signature) as $t |
      ($s.nontrivial_functions) as $nt |
      (n(":solved") + n(":solved_multi")) as $ntex |
      def pct(a; b): if b == 0 then "-" else ((a * 1000 / b | round) / 10 | tostring) + "%" end;
      "| \($c) | \($t) | \($ex) (\(pct($ex; $t))) | \($am) (\(pct($am; $t))) | \($un) (\(pct($un; $t))) | \($x.stored_clauses_exact)/\($s.stored_clauses) (\(pct($x.stored_clauses_exact; $s.stored_clauses))) | \($nt) | \($ntex) | \($am) | \($un) | \($x.replay_check.exact_wrong) / \($x.replay_check.ambiguous_unsound) / \($x.replay_check.no_solution) |"
    ' "$f"
  done
done
